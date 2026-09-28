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
    private var repoRootCache: [String: String?] = [:]
    private var resolveGeneration: UInt64 = 0
    /// Set when the target's repository changed and no page has been
    /// generated for it yet; cleared when production starts.
    private var needsPage = false
    /// Set when the panel becomes active again; the existing page refreshes
    /// once the target is settled.
    private var needsRefresh = false
    private var loadGeneration: UInt64 = 0
    private var loadTask: Task<Void, Never>?
    private var watch: GitStatusRepositoryWatch?
    private var watchRepoRoot: String?
    private var watchStartTask: Task<Void, Never>?
    private var watchEventsTask: Task<Void, Never>?
    private var watchGeneration: UInt64 = 0

    init(
        repoRootResolver: @escaping RepoRootResolver = RightSidebarChangesStore.defaultRepoRootResolver,
        pageProducer: @escaping PageProducer = RightSidebarChangesStore.defaultPageProducer,
        watchFactory: @escaping GitStatusRepositoryWatchFactory = GitStatusRepositoryWatching.defaultFactory,
        schemeHandler: CmuxDiffViewerURLSchemeHandler = .shared
    ) {
        self.repoRootResolver = repoRootResolver
        self.pageProducer = pageProducer
        self.watchFactory = watchFactory
        self.schemeHandler = schemeHandler
    }

    deinit {
        loadTask?.cancel()
        watchStartTask?.cancel()
        watchEventsTask?.cancel()
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
            // A directory probed as "not a repository" while hidden may have
            // been `git init`ed since; only positive answers stay cached.
            repoRootCache = repoRootCache.filter { $0.value != nil }
            // Edits made while the panel was hidden were not watched.
            needsRefresh = true
        }
        guard let workspaceId, let directory = directory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directory.isEmpty else {
            setTarget(nil, state: .noWorkspace)
            return
        }
        guard !isRemote else {
            setTarget(nil, state: .failed(message: String(
                localized: "rightSidebar.changes.remoteUnsupported",
                defaultValue: "Changes are available for local workspaces only."
            )))
            return
        }
        if let cached = repoRootCache[directory] {
            applyResolvedRepoRoot(cached, directory: directory, workspaceId: workspaceId)
            return
        }
        resolveGeneration &+= 1
        let generation = resolveGeneration
        let resolver = repoRootResolver
        Task { [weak self] in
            let repoRoot = await resolver(directory)
            guard let self, self.resolveGeneration == generation else { return }
            // `.some(nil)` records "not a repository" so the lookup is not repeated.
            self.repoRootCache[directory] = .some(repoRoot)
            self.applyResolvedRepoRoot(repoRoot, directory: directory, workspaceId: workspaceId)
        }
    }

    /// Window teardown: drops the watcher and any in-flight work. The page
    /// stays so a re-shown panel does not flash.
    func stop() {
        isActive = false
        resolveGeneration &+= 1
        if loadTask != nil {
            loadTask?.cancel(); loadTask = nil
            needsPage = true
        }
        stopWatch()
    }

    // MARK: Target

    private func applyResolvedRepoRoot(_ repoRoot: String?, directory: String, workspaceId: UUID) {
        guard let repoRoot else {
            setTarget(nil, state: .notARepository(path: directory))
            return
        }
        let next = RightSidebarChangesTarget(workspaceId: workspaceId, repoRoot: repoRoot)
        // Same repository under another workspace keeps the page (the diff is
        // a property of the repository); another repository starts over.
        if target?.repoRoot != repoRoot {
            loadTask?.cancel(); loadTask = nil
            page = nil
            needsPage = true
            state = .loading(previousURL: state.displayedURL)
        }
        if target != next { target = next }
        reconcile()
    }

    private func setTarget(_ target: RightSidebarChangesTarget?, state: RightSidebarChangesViewerState) {
        loadTask?.cancel(); loadTask = nil
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

    private func producePage(for target: RightSidebarChangesTarget) {
        loadTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        let producer = pageProducer
        let handler = schemeHandler
        let launch = DiffViewerCLILaunch.current()
        loadTask = Task { [weak self] in
            do {
                let page = try await producer(target, launch)
                try Task.checkCancellation()
                try await handler.register(token: page.token, files: page.allowedFiles)
                try Task.checkCancellation()
                guard let self, self.loadGeneration == generation, self.target == target else { return }
                self.loadTask = nil
                self.page = page
                self.state = .ready(url: page.url)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.loadGeneration == generation, self.target == target else { return }
                self.loadTask = nil
                self.page = nil
                self.state = .failed(message: error.localizedDescription)
            }
        }
    }

    // MARK: Refresh

    /// Applies one repository change: reloadable pages reload in place, static
    /// pages regenerate. Bursts are already folded by the repository watch's
    /// coalescing window, so each event is one refresh.
    func handleRepositoryChange() {
        guard isActive else { return }
        refreshExistingPage()
    }

    private func refreshExistingPage() {
        guard let target, let page else { return }
        if page.reloadable {
            reloadGeneration &+= 1
        } else {
            // Keep the current document on screen while the replacement renders.
            producePage(for: target)
        }
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
        try await Task.detached(priority: .userInitiated) {
            try RightSidebarChangesProcessRunner.producePage(target: target, launch: launch)
        }.value
    }
}

// MARK: - Process helpers

enum RightSidebarChangesProcessRunner {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Blocking; call from a detached task.
    static func producePage(
        target: RightSidebarChangesTarget,
        launch: DiffViewerCLILaunch?
    ) throws -> RightSidebarChangesPage {
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
        let stderr = PipeDrain(stderrPipe)
        try process.run()
        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stderrOutput = String(decoding: stderr.finish(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw Failure(message: Self.failureMessage(
                stderr: stderrOutput,
                stdout: String(decoding: stdout, as: UTF8.self),
                status: process.terminationStatus
            ))
        }
        return try decodePage(from: stdout)
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

    private static func failureMessage(stderr: String, stdout: String, status: Int32) -> String {
        for output in [stderr, stdout] {
            let lines = output
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if let last = lines.last {
                return last
            }
        }
        return String(
            localized: "rightSidebar.changes.error.cliFailed",
            defaultValue: "cmux diff exited with status \(status)."
        )
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
