import CmuxBrowser
import CmuxFoundation
import CmuxSettings
import Combine
import Foundation

// MARK: - Model

/// One generated `cmux diff --unstaged` viewer document for the right sidebar's
/// Changes panel. Produced by the hidden `cmux __diff-viewer-page` verb, which
/// reuses the diff viewer writers without opening a browser split.
struct RightSidebarChangesPage: Equatable, Sendable {
    /// Custom-scheme (`cmux-diff-viewer://<token>/<page>`) URL the panel loads.
    let url: URL
    /// Capability token (the URL host) that scopes the scheme handler session.
    let token: String
    /// Allowlist the scheme handler may serve for `token`.
    let allowedFiles: [CmuxDiffViewerRegisteredFile]
    /// Whether `webView.reload()` recomputes the diff (typed sidecar session)
    /// or the document is a static snapshot that must be regenerated.
    let reloadable: Bool
}

/// What the Changes panel shows.
enum RightSidebarChangesViewerState: Equatable {
    case noWorkspace
    case notARepository(path: String)
    /// A page is being generated. `previousURL` is the document still on
    /// screen from the last repository, so the panel can keep its web view
    /// mounted and overlay a progress indicator instead of remounting.
    case loading(previousURL: URL?)
    case ready(url: URL)
    case failed(message: String)

    /// The document the panel's web view should currently display, if any.
    var displayedURL: URL? {
        switch self {
        case .ready(let url): return url
        case .loading(let previousURL): return previousURL
        case .noWorkspace, .notARepository, .failed: return nil
        }
    }
}

/// The repository the Changes panel currently follows.
struct RightSidebarChangesTarget: Equatable, Sendable {
    let workspaceId: UUID
    let repoRoot: String
}

// MARK: - Pure policy

/// UI-free decisions for the Changes panel's automatic refresh.
enum RightSidebarChangesRefreshPolicy {
    /// The watcher only runs while the panel is actually on screen.
    static func shouldWatch(isRightSidebarVisible: Bool, mode: RightSidebarMode) -> Bool {
        isRightSidebarVisible && mode == .changes
    }
}

// MARK: - Store

/// Per-window state for the right sidebar's Changes mode: resolves the selected
/// workspace's repository, generates the diff viewer document through the CLI,
/// installs its scheme-handler session, and refreshes it when the repository
/// changes on disk while the panel is visible.
///
/// Nothing is produced or watched while the panel is hidden; `sync` runs on
/// every workspace switch and directory change, so an inactive store only
/// records where it should look when it next becomes active.
@MainActor
final class RightSidebarChangesStore: ObservableObject {
    typealias RepoRootResolver = @Sendable (_ directory: String) async -> String?
    typealias PageProducer = @Sendable (
        _ target: RightSidebarChangesTarget,
        _ launch: DiffViewerCLILaunch?
    ) async throws -> RightSidebarChangesPage

    /// How long one page production may take before the panel reports a
    /// failure instead of spinning; the CLI child is terminated on the way out.
    static let defaultProductionTimeout: TimeInterval = 60
    /// Positive repository probes kept per directory; the oldest is dropped.
    static let repoRootCacheLimit = 64
    /// Pages kept for repositories the panel showed recently, so returning to
    /// one reuses its document instead of spawning the CLI again.
    static let recentPageLimit = 4

    @Published private(set) var state: RightSidebarChangesViewerState = .noWorkspace
    /// Bumped when the hosted web view should `reload()` the current page.
    @Published private(set) var reloadGeneration: UInt64 = 0
    /// Published so the hosted web view re-associates with the workspace when
    /// the same repository is shown under another workspace.
    @Published private(set) var target: RightSidebarChangesTarget?

    private(set) var page: RightSidebarChangesPage?
    private(set) var isActive = false

    private let repoRootResolver: RepoRootResolver
    private let pageProducer: PageProducer
    private let watchFactory: GitStatusRepositoryWatchFactory
    private let schemeHandler: CmuxDiffViewerURLSchemeHandler
    private let productionTimeout: TimeInterval
    /// Positive probes only, most recently used last. Negative answers are
    /// never cached: a `git init` in the selected directory must show up on
    /// the next sync, and a negative probe is one cheap `git rev-parse`.
    private var repoRootCache: [String: String] = [:]
    private var repoRootCacheOrder: [String] = []
    /// The probe in flight, so a burst of syncs for one directory waits for
    /// the answer instead of spawning `git` per sync.
    private var pendingProbe: (directory: String, workspaceId: UUID)?
    private var resolveGeneration: UInt64 = 0
    /// Set when the target's repository changed and no page has been
    /// generated for it yet; cleared when production starts.
    private var needsPage = false
    /// Set when the panel becomes active again or comes back to a recently
    /// shown repository; the existing page refreshes once the target settles.
    private var needsRefresh = false
    private var loadGeneration: UInt64 = 0
    private var loadTask: Task<Void, Never>?
    /// Pages by repository root, most recently shown last. Every page here
    /// keeps its scheme session registered; eviction or replacement drops it.
    private var recentPages: [(repoRoot: String, page: RightSidebarChangesPage)] = []
    private var watch: GitStatusRepositoryWatch?
    private var watchRepoRoot: String?
    private var watchStartTask: Task<Void, Never>?
    private var watchEventsTask: Task<Void, Never>?
    private var watchGeneration: UInt64 = 0
    private let fingerprintProducer: RightSidebarChangesFingerprint.Producer
    /// The working-tree digest the displayed page reflects; `nil` until the
    /// seed taken after a page installs has landed (or when it failed).
    private var lastFingerprint: String?
    /// One digest runs at a time; events arriving meanwhile fold into a single
    /// re-check once it lands, so a burst costs two `git status` runs at most.
    private var fingerprintTask: Task<Void, Never>?
    private var fingerprintRecheckPending = false
    private var fingerprintGeneration: UInt64 = 0
    /// Completed digest runs (tests).
    private(set) var fingerprintCheckCount = 0

    init(
        repoRootResolver: @escaping RepoRootResolver = RightSidebarChangesStore.defaultRepoRootResolver,
        pageProducer: @escaping PageProducer = RightSidebarChangesStore.defaultPageProducer,
        watchFactory: @escaping GitStatusRepositoryWatchFactory = GitStatusRepositoryWatching.defaultFactory,
        schemeHandler: CmuxDiffViewerURLSchemeHandler = .shared,
        productionTimeout: TimeInterval = RightSidebarChangesStore.defaultProductionTimeout,
        fingerprintProducer: @escaping RightSidebarChangesFingerprint.Producer = RightSidebarChangesFingerprint.defaultProducer
    ) {
        self.repoRootResolver = repoRootResolver
        self.pageProducer = pageProducer
        self.watchFactory = watchFactory
        self.schemeHandler = schemeHandler
        self.productionTimeout = productionTimeout
        self.fingerprintProducer = fingerprintProducer
    }

    deinit {
        loadTask?.cancel()
        fingerprintTask?.cancel()
        watchStartTask?.cancel()
        watchEventsTask?.cancel()
        // Nothing displays these documents any more; their sessions go too.
        let tokens = recentPages.map { $0.page.token }
        guard !tokens.isEmpty else { return }
        let handler = schemeHandler
        Task { @MainActor in
            for token in tokens { handler.unregister(token: token) }
        }
    }

    // MARK: Inputs

    /// Mirrors `FileExplorerStore.syncWorkspaceRoot`: the window calls this on
    /// every selection, directory, visibility, or mode change.
    func sync(workspace: Workspace?, isRightSidebarVisible: Bool, mode: RightSidebarMode) {
        let isActive = RightSidebarChangesRefreshPolicy.shouldWatch(
            isRightSidebarVisible: isRightSidebarVisible,
            mode: mode
        )
        guard let workspace else {
            update(directory: nil, workspaceId: nil, isRemote: false, isActive: isActive)
            return
        }
        update(
            directory: workspace.resolvedWorkingDirectory(),
            workspaceId: workspace.id,
            isRemote: workspace.usesRemoteDirectoryProvenance,
            isActive: isActive
        )
    }

    /// Workspace-free entry point (the piece tests drive directly).
    func update(directory: String?, workspaceId: UUID?, isRemote: Bool, isActive: Bool) {
        let becameActive = isActive && !self.isActive
        self.isActive = isActive
        if becameActive {
            // Edits made while the panel was hidden were not watched.
            needsRefresh = true
        }
        guard let workspaceId, let directory = directory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directory.isEmpty else {
            invalidatePendingProbe()
            setTarget(nil, state: .noWorkspace)
            return
        }
        guard !isRemote else {
            invalidatePendingProbe()
            setTarget(nil, state: .failed(message: String(
                localized: "rightSidebar.changes.remoteUnsupported",
                defaultValue: "Changes are available for local workspaces only."
            )))
            return
        }
        if let cached = repoRootCache[directory] {
            invalidatePendingProbe()
            touchRepoRootCache(directory)
            applyResolvedRepoRoot(cached, directory: directory, workspaceId: workspaceId)
            return
        }
        // The same question is already being asked; its answer will apply.
        if let pendingProbe, pendingProbe.directory == directory, pendingProbe.workspaceId == workspaceId {
            return
        }
        resolveGeneration &+= 1
        let generation = resolveGeneration
        pendingProbe = (directory, workspaceId)
        let resolver = repoRootResolver
        Task { [weak self] in
            let repoRoot = await resolver(directory)
            guard let self, self.resolveGeneration == generation else { return }
            self.pendingProbe = nil
            if let repoRoot { self.cacheRepoRoot(repoRoot, for: directory) }
            self.applyResolvedRepoRoot(repoRoot, directory: directory, workspaceId: workspaceId)
        }
    }

    /// Window teardown: drops the watcher, any in-flight work, and every kept
    /// page's scheme session (nothing displays them any more). A later sync
    /// regenerates the page for the recorded target.
    func stop() {
        isActive = false
        invalidatePendingProbe()
        cancelLoad()
        stopWatch()
        for entry in recentPages {
            schemeHandler.unregister(token: entry.page.token)
        }
        recentPages = []
        page = nil
        if target != nil {
            needsPage = true
            if state != .loading(previousURL: nil) { state = .loading(previousURL: nil) }
        }
    }

    // MARK: Repository probes

    private func invalidatePendingProbe() {
        guard pendingProbe != nil else { return }
        pendingProbe = nil
        resolveGeneration &+= 1
    }

    private func cacheRepoRoot(_ repoRoot: String, for directory: String) {
        repoRootCache[directory] = repoRoot
        touchRepoRootCache(directory)
        while repoRootCacheOrder.count > Self.repoRootCacheLimit {
            let oldest = repoRootCacheOrder.removeFirst()
            repoRootCache.removeValue(forKey: oldest)
        }
    }

    private func touchRepoRootCache(_ directory: String) {
        repoRootCacheOrder.removeAll { $0 == directory }
        repoRootCacheOrder.append(directory)
    }

    /// Directories with a cached positive answer, oldest first (tests).
    var cachedRepoRootDirectories: [String] { repoRootCacheOrder }

    // MARK: Target

    private func applyResolvedRepoRoot(_ repoRoot: String?, directory: String, workspaceId: UUID) {
        guard let repoRoot else {
            setTarget(nil, state: .notARepository(path: directory))
            return
        }
        let next = RightSidebarChangesTarget(workspaceId: workspaceId, repoRoot: repoRoot)
        // Same repository under another workspace keeps the page and any
        // in-flight load (the diff is a property of the repository); another
        // repository starts over, or comes straight back if it was shown recently.
        if target?.repoRoot != repoRoot {
            cancelLoad()
            if let recent = recentPage(for: repoRoot) {
                page = recent
                needsPage = false
                // Edits made while this repository was not watched went unseen.
                needsRefresh = true
                state = .ready(url: recent.url)
            } else {
                page = nil
                needsPage = true
                state = .loading(previousURL: state.displayedURL)
            }
        }
        if target != next { target = next }
        reconcile()
    }

    private func setTarget(_ target: RightSidebarChangesTarget?, state: RightSidebarChangesViewerState) {
        cancelLoad()
        needsPage = false
        if self.target != target { self.target = target }
        page = nil
        if self.state != state { self.state = state }
        reconcile()
    }

    /// Brings production and the watcher in line with `isActive` and `target`.
    private func reconcile() {
        guard isActive, let target else {
            stopWatch()
            return
        }
        if needsPage {
            needsPage = false
            needsRefresh = false
            producePage(for: target)
        } else if needsRefresh {
            needsRefresh = false
            refreshExistingPage()
        }
        syncWatch(repoRoot: target.repoRoot)
    }

    // MARK: Page production

    /// Cancels the in-flight load. Bumping the generation also retires a
    /// producer that ignores cancellation, so its late result is dropped.
    private func cancelLoad() {
        guard loadTask != nil else { return }
        loadTask?.cancel()
        loadTask = nil
        loadGeneration &+= 1
    }

    /// Whether a load started at `generation` for `repoRoot` is still the one
    /// the panel is waiting for. The workspace is deliberately not compared:
    /// a same-repository workspace switch keeps the load and only retargets.
    private func isCurrentLoad(_ generation: UInt64, repoRoot: String) -> Bool {
        loadGeneration == generation && target?.repoRoot == repoRoot
    }

    private func producePage(for target: RightSidebarChangesTarget) {
        cancelLoad()
        loadGeneration &+= 1
        let generation = loadGeneration
        let producer = pageProducer
        let handler = schemeHandler
        let launch = DiffViewerCLILaunch.current()
        let timeout = productionTimeout
        let repoRoot = target.repoRoot
        loadTask = Task { [weak self] in
            do {
                let page = try await RightSidebarChangesProductionRace.run(timeout: timeout) {
                    try await producer(target, launch)
                }
                // Register only for a load the panel still waits for; the
                // session would otherwise outlive any document that uses it.
                guard let self, self.isCurrentLoad(generation, repoRoot: repoRoot) else { return }
                try await handler.register(token: page.token, files: page.allowedFiles)
                guard self.isCurrentLoad(generation, repoRoot: repoRoot) else {
                    handler.unregister(token: page.token)
                    return
                }
                self.loadTask = nil
                self.installPage(page, for: repoRoot)
                self.state = .ready(url: page.url)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.isCurrentLoad(generation, repoRoot: repoRoot) else { return }
                self.loadTask = nil
                self.page = nil
                self.state = .failed(message: error.localizedDescription)
            }
        }
    }

    /// Makes `page` current and remembers it for `repoRoot`, dropping the
    /// session of the page it replaces and of the least recently shown page
    /// past the limit. Neither is on screen: the replaced page's repository
    /// now displays `page`, and the evicted one is four repositories back.
    private func installPage(_ page: RightSidebarChangesPage, for repoRoot: String) {
        self.page = page
        // The new document reflects the working tree as of now; record that
        // digest so the first unrelated event afterwards does not reload it.
        seedFingerprint()
        if let index = recentPages.firstIndex(where: { $0.repoRoot == repoRoot }) {
            let replaced = recentPages.remove(at: index).page
            if replaced.token != page.token {
                schemeHandler.unregister(token: replaced.token)
            }
        }
        recentPages.append((repoRoot, page))
        while recentPages.count > Self.recentPageLimit {
            let evicted = recentPages.removeFirst().page
            schemeHandler.unregister(token: evicted.token)
        }
    }

    /// The kept page for `repoRoot`, made most recent, if its session is
    /// still installed (the handler expires sessions after a day).
    private func recentPage(for repoRoot: String) -> RightSidebarChangesPage? {
        guard let index = recentPages.firstIndex(where: { $0.repoRoot == repoRoot }) else { return nil }
        let entry = recentPages.remove(at: index)
        guard schemeHandler.hasActiveSession(token: entry.page.token) else { return nil }
        recentPages.append(entry)
        return entry.page
    }

    /// Repository roots with a kept page, least recently shown first (tests).
    var recentPageRepoRoots: [String] { recentPages.map(\.repoRoot) }

    // MARK: Refresh

    /// Applies one repository change. The watch's coalescing window folds a
    /// burst into one event, but not every event changes the working-tree
    /// diff: the digest decides, and only a changed (or unobtainable) digest
    /// refreshes the page.
    func handleRepositoryChange() {
        guard isActive, target != nil, page != nil else { return }
        scheduleFingerprintCheck(refreshOnChange: true)
    }

    /// A page that a `needsRefresh` or a static regeneration replaces reflects
    /// the working tree as of the check; the digest recorded with it decides
    /// what the next event means.
    private func refreshExistingPage() {
        guard let target, let page else { return }
        if page.reloadable {
            reloadGeneration &+= 1
            seedFingerprint()
        } else {
            // Keep the current document on screen while the replacement renders.
            producePage(for: target)
        }
    }

    // MARK: Working-tree digest

    /// Records the digest the displayed page corresponds to, without refreshing.
    private func seedFingerprint() {
        lastFingerprint = nil
        scheduleFingerprintCheck(refreshOnChange: false)
    }

    /// Runs one digest for the current target. While one is in flight, a
    /// further request only marks a re-check, which runs once it lands.
    private func scheduleFingerprintCheck(refreshOnChange: Bool) {
        guard let target else { return }
        if fingerprintTask != nil {
            if refreshOnChange { fingerprintRecheckPending = true }
            return
        }
        fingerprintGeneration &+= 1
        let generation = fingerprintGeneration
        let producer = fingerprintProducer
        let repoRoot = target.repoRoot
        fingerprintTask = Task { [weak self] in
            let fingerprint = await producer(repoRoot)
            guard let self, !Task.isCancelled, self.fingerprintGeneration == generation,
                  self.target?.repoRoot == repoRoot else { return }
            self.fingerprintTask = nil
            self.fingerprintCheckCount += 1
            let recheck = self.fingerprintRecheckPending
            self.fingerprintRecheckPending = false
            if refreshOnChange, self.isActive, fingerprint == nil || fingerprint != self.lastFingerprint {
                self.lastFingerprint = fingerprint
                // Refreshing re-seeds; a pending re-check is covered by it.
                self.refreshExistingPage()
                return
            }
            self.lastFingerprint = fingerprint
            if recheck { self.scheduleFingerprintCheck(refreshOnChange: true) }
        }
    }

    private func cancelFingerprintCheck() {
        fingerprintGeneration &+= 1
        fingerprintTask?.cancel()
        fingerprintTask = nil
        fingerprintRecheckPending = false
        lastFingerprint = nil
    }

    // MARK: Watch

    private func syncWatch(repoRoot: String) {
        // Already watching, or still starting, the right repository.
        if watchRepoRoot == repoRoot { return }
        stopWatch()
        watchGeneration &+= 1
        let generation = watchGeneration
        watchRepoRoot = repoRoot
        let factory = watchFactory
        watchStartTask = Task { [weak self] in
            let watch = await factory(repoRoot)
            guard let self, self.watchGeneration == generation, !Task.isCancelled else {
                if let watch { await watch.stop() }
                return
            }
            self.watchStartTask = nil
            guard let watch else {
                self.watchRepoRoot = nil
                return
            }
            self.watch = watch
            let events = watch.events
            self.watchEventsTask = Task { @MainActor [weak self] in
                for await _ in events {
                    // Rebound per event: a strong `self` for the stream's
                    // lifetime would keep a closed window's store alive.
                    guard let self, !Task.isCancelled, self.watchGeneration == generation else { break }
                    self.handleRepositoryChange()
                }
            }
        }
    }

    private func stopWatch() {
        cancelFingerprintCheck()
        watchGeneration &+= 1
        watchStartTask?.cancel(); watchStartTask = nil
        watchEventsTask?.cancel(); watchEventsTask = nil
        watchRepoRoot = nil
        guard let watch else { return }
        self.watch = nil
        Task.detached(priority: .utility) { await watch.stop() }
    }

    var isWatching: Bool { watch != nil }

    // MARK: Defaults

    /// The canonical repository root off the main actor; nil outside a repository.
    static let defaultRepoRootResolver: RepoRootResolver = { directory in
        await Task.detached(priority: .userInitiated) {
            GitStatusProvider().repositoryRoot(for: directory)
        }.value
    }

    /// Runs the bundled CLI's hidden `__diff-viewer-page` verb the same way the
    /// Cmd+Shift+D diff viewer launches `cmux diff`, and decodes its JSON.
    static let defaultPageProducer: PageProducer = { target, launch in
        try await RightSidebarChangesProcessRunner.producePage(target: target, launch: launch)
    }
}

// MARK: - Production race

/// Runs one page production against a deadline. Whichever finishes first
/// settles the result; the loser is cancelled. A producer that ignores
/// cancellation is abandoned rather than awaited, so the panel always leaves
/// `.loading` once the deadline passes.
enum RightSidebarChangesProductionRace {
    struct Timeout: LocalizedError, Equatable {
        var errorDescription: String? {
            String(
                localized: "rightSidebar.changes.error.timedOut",
                defaultValue: "cmux diff did not finish in time."
            )
        }
    }

    static func run(
        timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> RightSidebarChangesPage
    ) async throws -> RightSidebarChangesPage {
        let race = Race()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(continuation: continuation, timeout: timeout, operation: operation)
            }
        } onCancel: {
            race.cancel()
        }
    }

    private final class Race: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<RightSidebarChangesPage, Error>?
        private var producer: Task<Void, Never>?
        private var deadline: Task<Void, Never>?
        private var isCancelled = false

        func start(
            continuation: CheckedContinuation<RightSidebarChangesPage, Error>,
            timeout: TimeInterval,
            operation: @escaping @Sendable () async throws -> RightSidebarChangesPage
        ) {
            lock.lock()
            if isCancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            producer = Task.detached(priority: .userInitiated) { [self] in
                do {
                    let page = try await operation()
                    self.finish(.success(page))
                } catch {
                    self.finish(.failure(error))
                }
            }
            deadline = Task.detached(priority: .utility) { [self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.finish(.failure(Timeout()))
            }
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            lock.unlock()
            finish(.failure(CancellationError()))
        }

        private func finish(_ result: Result<RightSidebarChangesPage, Error>) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            let producer = self.producer
            let deadline = self.deadline
            self.producer = nil
            self.deadline = nil
            lock.unlock()
            guard let continuation else { return }
            producer?.cancel()
            deadline?.cancel()
            continuation.resume(with: result)
        }
    }
}

// MARK: - Process helpers

enum RightSidebarChangesProcessRunner {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs the CLI verb and decodes its page. Cancelling the calling task
    /// (another repository, panel teardown, the store's deadline) terminates
    /// the child instead of leaving it to finish on its own.
    static func producePage(
        target: RightSidebarChangesTarget,
        launch: DiffViewerCLILaunch?
    ) async throws -> RightSidebarChangesPage {
        guard let launch else {
            throw Failure(message: String(
                localized: "rightSidebar.changes.error.cliMissing",
                defaultValue: "The bundled cmux command line tool is missing."
            ))
        }
        let process = launch.makeProcess(
            command: "__diff-viewer-page",
            cwd: target.repoRoot,
            workspaceId: target.workspaceId
        )
        // The verb prints exactly one JSON document on stdout; diagnostics go
        // to stderr. Both are drained concurrently so neither pipe fills up.
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdout = PipeDrain(stdoutPipe)
        let stderr = PipeDrain(stderrPipe)
        let child = ChildProcess(process)
        try child.run()
        let status = await withTaskCancellationHandler {
            await child.waitForExit()
        } onCancel: {
            child.terminate()
        }
        try Task.checkCancellation()
        let stderrOutput = String(decoding: stderr.finish(), as: UTF8.self)
        let stdoutData = stdout.finish()
        guard status == 0 else {
            throw Failure(message: Self.failureMessage(
                stderr: stderrOutput,
                stdout: String(decoding: stdoutData, as: UTF8.self),
                status: status
            ))
        }
        return try decodePage(from: stdoutData)
    }

    /// Strict decode of the verb's `{"url", "allowed_files", "reloadable"}`
    /// payload; the token is the URL host.
    static func decodePage(from output: Data) throws -> RightSidebarChangesPage {
        let invalidPage = Failure(message: String(
            localized: "rightSidebar.changes.error.invalidPage",
            defaultValue: "The diff viewer did not return a usable page."
        ))
        guard let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let rawURL = object["url"] as? String,
              let url = URL(string: rawURL),
              let token = url.host,
              CmuxDiffViewerURLSchemeHandler.isValidToken(token),
              let rawFiles = object["allowed_files"] as? [[String: Any]] else {
            throw invalidPage
        }
        let files = rawFiles.compactMap(CmuxDiffViewerURLSchemeHandler.registeredFile(from:))
        guard files.count == rawFiles.count, !files.isEmpty else {
            throw invalidPage
        }
        return RightSidebarChangesPage(
            url: url,
            token: token,
            allowedFiles: files,
            reloadable: object["reloadable"] as? Bool ?? false
        )
    }

    /// The panel-facing failure text. Like the Cmd+Shift+D pane, this never
    /// surfaces the child's output (paths, git remotes, whatever the verb
    /// printed); the last output line only goes to the debug log.
    static func failureMessage(stderr: String, stdout: String, status: Int32) -> String {
        #if DEBUG
        if let detail = lastNonEmptyLine(in: stderr) ?? lastNonEmptyLine(in: stdout) {
            cmuxDebugLog("rightSidebar.changes.producer.failed status=\(status) detail=\(detail)")
        }
        #endif
        return String(
            localized: "rightSidebar.changes.error.cliFailed",
            defaultValue: "cmux diff exited with status \(status)."
        )
    }

    private static func lastNonEmptyLine(in output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    /// Owns one launched `Process` across the cancellation boundary: exit is
    /// awaited through its termination handler and `terminate()` is safe from
    /// any thread, including a cancellation handler that runs after exit.
    private final class ChildProcess: @unchecked Sendable {
        private let process: Process
        private let lock = NSLock()
        private var didExit = false
        private var continuation: CheckedContinuation<Int32, Never>?

        init(_ process: Process) {
            self.process = process
        }

        func run() throws {
            process.terminationHandler = { [self] process in
                self.lock.lock()
                self.didExit = true
                let continuation = self.continuation
                self.continuation = nil
                self.lock.unlock()
                continuation?.resume(returning: process.terminationStatus)
            }
            try process.run()
        }

        func waitForExit() async -> Int32 {
            await withCheckedContinuation { continuation in
                lock.lock()
                if didExit {
                    lock.unlock()
                    continuation.resume(returning: process.terminationStatus)
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        }

        func terminate() {
            lock.lock()
            let running = !didExit && process.isRunning
            lock.unlock()
            if running { process.terminate() }
        }
    }

    /// Reads one pipe to end-of-file on a background queue so the child never
    /// blocks on a full pipe buffer while the caller reads the other pipe.
    private final class PipeDrain: @unchecked Sendable {
        private let handle: FileHandle
        private let group = DispatchGroup()
        private var data = Data()

        init(_ pipe: Pipe) {
            handle = pipe.fileHandleForReading
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                self.data = self.handle.readDataToEndOfFile()
                self.group.leave()
            }
        }

        func finish() -> Data {
            group.wait()
            return data
        }
    }
}
