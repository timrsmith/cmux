import CmuxBrowser
import CmuxFoundation
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Pure policy

final class RightSidebarChangesRefreshPolicyTests: XCTestCase {
    func testWatchesOnlyWhileVisibleInChangesMode() {
        XCTAssertTrue(RightSidebarChangesRefreshPolicy.shouldWatch(isRightSidebarVisible: true, mode: .changes))
        XCTAssertFalse(RightSidebarChangesRefreshPolicy.shouldWatch(isRightSidebarVisible: false, mode: .changes))
        for mode in RightSidebarMode.allCases where mode != .changes {
            XCTAssertFalse(
                RightSidebarChangesRefreshPolicy.shouldWatch(isRightSidebarVisible: true, mode: mode),
                "\(mode) must not start the repository watcher"
            )
        }
    }

    func testDisplayedURLKeepsThePreviousDocumentWhileLoading() throws {
        let url = try XCTUnwrap(URL(string: "cmux-diff-viewer://0123456789abcdef/index.html"))
        XCTAssertEqual(RightSidebarChangesViewerState.ready(url: url).displayedURL, url)
        XCTAssertEqual(RightSidebarChangesViewerState.loading(previousURL: url).displayedURL, url)
        XCTAssertNil(RightSidebarChangesViewerState.loading(previousURL: nil).displayedURL)
        XCTAssertNil(RightSidebarChangesViewerState.noWorkspace.displayedURL)
        XCTAssertNil(RightSidebarChangesViewerState.notARepository(path: "/tmp").displayedURL)
        XCTAssertNil(RightSidebarChangesViewerState.failed(message: "x").displayedURL)
    }
}

// MARK: - Fakes

/// Hand-driven stand-in for the git-aware repository watch: records which
/// repository roots the store asked to watch and lets a test fire events.
final class ScriptedRepositoryWatchSource: @unchecked Sendable {
    private let lock = NSLock()
    private var continuationsByRepoRoot: [String: AsyncStream<Void>.Continuation] = [:]
    private var startedStorage: [String] = []
    private var stoppedStorage: [String] = []

    /// Every repository root a watch was requested for, in order.
    var startedRepoRoots: [String] {
        lock.lock(); defer { lock.unlock() }
        return startedStorage
    }

    var stoppedRepoRoots: [String] {
        lock.lock(); defer { lock.unlock() }
        return stoppedStorage
    }

    var factory: GitStatusRepositoryWatchFactory {
        { [self] repoRoot in
            let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            self.lock.lock()
            self.continuationsByRepoRoot[repoRoot] = continuation
            self.startedStorage.append(repoRoot)
            self.lock.unlock()
            return GitStatusRepositoryWatch(events: events) { [self] in
                self.lock.lock()
                self.stoppedStorage.append(repoRoot)
                self.lock.unlock()
                continuation.finish()
            }
        }
    }

    func fire(repoRoot: String) {
        lock.lock()
        let continuation = continuationsByRepoRoot[repoRoot]
        lock.unlock()
        continuation?.yield(())
    }
}

/// Hands out pages in order and records how many were requested.
final class ScriptedChangesPageProducer: @unchecked Sendable {
    private let lock = NSLock()
    private let pages: [RightSidebarChangesPage]
    private var callCountStorage = 0

    init(pages: [RightSidebarChangesPage]) {
        self.pages = pages
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return callCountStorage
    }

    func produce() -> RightSidebarChangesPage {
        lock.lock(); defer { lock.unlock() }
        let page = pages[min(callCountStorage, pages.count - 1)]
        callCountStorage += 1
        return page
    }
}

// MARK: - Store

@MainActor
final class RightSidebarChangesStoreTests: XCTestCase {
    private let repoRoot = "/tmp/cmux-changes-tests/repo"
    private let otherRepoRoot = "/tmp/cmux-changes-tests/other"
    private var fixtureURLs: [URL] = []
    private var leaseURLs: [URL] = []

    override func tearDown() {
        for url in fixtureURLs { try? FileManager.default.removeItem(at: url) }
        for url in leaseURLs { try? FileManager.default.removeItem(at: url) }
        fixtureURLs = []
        leaseURLs = []
        super.tearDown()
    }

    /// A trusted-root page the real `CmuxDiffViewerSessionPreparer` accepts,
    /// like `DiffViewerURLSchemeHandlerLifecycleTests`.
    private func makePage(reloadable: Bool) throws -> RightSidebarChangesPage {
        let token = UUID().uuidString.lowercased()
        let rootURL = CmuxDiffViewerSessionPreparer.defaultTrustedRootURL
        let fixtureURL = rootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let entryURL = fixtureURL.appendingPathComponent("index.html", isDirectory: false)
        try FileManager.default.createDirectory(at: fixtureURL, withIntermediateDirectories: true)
        try "<!doctype html><title>changes</title>".write(to: entryURL, atomically: true, encoding: .utf8)
        fixtureURLs.append(fixtureURL)
        leaseURLs.append(rootURL.appendingPathComponent(".session-lease-\(token).lock", isDirectory: false))
        return RightSidebarChangesPage(
            url: try XCTUnwrap(URL(string: "cmux-diff-viewer://\(token)/index.html")),
            token: token,
            allowedFiles: [
                CmuxDiffViewerRegisteredFile(requestPath: "/index.html", fileURL: entryURL, mimeType: "text/html"),
            ],
            reloadable: reloadable
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting: \(message)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Directories under `.../repo` resolve to `repoRoot`, under `.../other`
    /// to `otherRepoRoot`; everything else is not a repository.
    private func makeStore(
        producer: ScriptedChangesPageProducer,
        watchSource: ScriptedRepositoryWatchSource,
        handler: CmuxDiffViewerURLSchemeHandler? = nil,
        repoRootResolver: RightSidebarChangesStore.RepoRootResolver? = nil
    ) -> RightSidebarChangesStore {
        // Default arguments evaluate outside the main actor, so the main-actor
        // handler is created here instead of as a `= CmuxDiffViewerURLSchemeHandler()` default.
        let handler = handler ?? CmuxDiffViewerURLSchemeHandler()
        let repoRoot = repoRoot
        let otherRepoRoot = otherRepoRoot
        let defaultResolver: RightSidebarChangesStore.RepoRootResolver = { directory in
            if directory == repoRoot || directory.hasPrefix(repoRoot + "/") { return repoRoot }
            if directory == otherRepoRoot || directory.hasPrefix(otherRepoRoot + "/") { return otherRepoRoot }
            return nil
        }
        return RightSidebarChangesStore(
            repoRootResolver: repoRootResolver ?? defaultResolver,
            pageProducer: { _, _ in producer.produce() },
            watchFactory: watchSource.factory,
            schemeHandler: handler
        )
    }

    func testStateMachineFollowsWorkspaceDirectoryAndInstallsSession() async throws {
        let page = try makePage(reloadable: true)
        let producer = ScriptedChangesPageProducer(pages: [page])
        let watchSource = ScriptedRepositoryWatchSource()
        let handler = CmuxDiffViewerURLSchemeHandler()
        let store = makeStore(producer: producer, watchSource: watchSource, handler: handler)
        let workspaceId = UUID()

        XCTAssertEqual(store.state, .noWorkspace)

        store.update(directory: nil, workspaceId: workspaceId, isRemote: false, isActive: true)
        XCTAssertEqual(store.state, .noWorkspace)

        store.update(directory: "/tmp/cmux-changes-tests/plain", workspaceId: workspaceId, isRemote: false, isActive: true)
        await waitUntil("not a repository") { store.state == .notARepository(path: "/tmp/cmux-changes-tests/plain") }
        XCTAssertEqual(producer.callCount, 0)
        XCTAssertFalse(store.isWatching)

        store.update(directory: repoRoot + "/Sources", workspaceId: workspaceId, isRemote: false, isActive: true)
        await waitUntil("ready") { store.state == .ready(url: page.url) }
        XCTAssertEqual(producer.callCount, 1)
        XCTAssertTrue(handler.hasActiveSession(token: page.token), "the allowlist is installed before the page shows")
        XCTAssertEqual(store.target, RightSidebarChangesTarget(workspaceId: workspaceId, repoRoot: repoRoot))
        await waitUntil("watching") { store.isWatching }
        XCTAssertEqual(watchSource.startedRepoRoots, [repoRoot], "the git-aware watch is keyed by repository root")

        // Another directory inside the same repository keeps the page and the watch.
        store.update(directory: repoRoot + "/Tests", workspaceId: workspaceId, isRemote: false, isActive: true)
        XCTAssertEqual(store.state, .ready(url: page.url))
        XCTAssertEqual(producer.callCount, 1)
        XCTAssertEqual(watchSource.startedRepoRoots, [repoRoot])

        // The same repository under another workspace only retargets.
        let otherWorkspaceId = UUID()
        store.update(directory: repoRoot, workspaceId: otherWorkspaceId, isRemote: false, isActive: true)
        await waitUntil("retargeted") { store.target?.workspaceId == otherWorkspaceId }
        XCTAssertEqual(store.state, .ready(url: page.url))
        XCTAssertEqual(store.target, RightSidebarChangesTarget(workspaceId: otherWorkspaceId, repoRoot: repoRoot))
        XCTAssertEqual(producer.callCount, 1)
        XCTAssertEqual(watchSource.startedRepoRoots, [repoRoot])

        store.update(directory: repoRoot, workspaceId: workspaceId, isRemote: true, isActive: true)
        guard case .failed = store.state else {
            return XCTFail("remote workspaces report an unavailable state, got \(store.state)")
        }
        XCTAssertFalse(store.isWatching)
        await waitUntil("watch torn down") { watchSource.stoppedRepoRoots == [self.repoRoot] }

        store.update(directory: nil, workspaceId: nil, isRemote: false, isActive: true)
        XCTAssertEqual(store.state, .noWorkspace)
    }

    func testPageProducerFailureIsReported() async throws {
        struct ProducerError: LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let watchSource = ScriptedRepositoryWatchSource()
        let repoRoot = repoRoot
        let store = RightSidebarChangesStore(
            repoRootResolver: { _ in repoRoot },
            pageProducer: { _, _ in throw ProducerError() },
            watchFactory: watchSource.factory,
            schemeHandler: CmuxDiffViewerURLSchemeHandler()
        )
        store.update(directory: repoRoot, workspaceId: UUID(), isRemote: false, isActive: true)
        await waitUntil("failed") { store.state == .failed(message: "boom") }

        // A failure is not retried on every sync; only a new repository is.
        store.update(directory: repoRoot + "/Sources", workspaceId: UUID(), isRemote: false, isActive: true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.state, .failed(message: "boom"))
    }

    func testInactivePanelRecordsTheTargetWithoutProducingAPage() async throws {
        let page = try makePage(reloadable: true)
        let producer = ScriptedChangesPageProducer(pages: [page])
        let watchSource = ScriptedRepositoryWatchSource()
        let store = makeStore(producer: producer, watchSource: watchSource)
        let workspaceId = UUID()

        // Workspace switches and directory changes while hidden never spawn the CLI.
        store.update(directory: repoRoot, workspaceId: workspaceId, isRemote: false, isActive: false)
        await waitUntil("target recorded") { store.target != nil }
        store.update(directory: repoRoot + "/Sources", workspaceId: workspaceId, isRemote: false, isActive: false)
        store.update(directory: repoRoot, workspaceId: UUID(), isRemote: false, isActive: false)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(producer.callCount, 0, "a hidden panel must not generate pages")
        XCTAssertEqual(store.state, .loading(previousURL: nil))
        XCTAssertFalse(store.isWatching)
        XCTAssertTrue(watchSource.startedRepoRoots.isEmpty)

        // Showing the panel produces the page exactly once and starts watching.
        store.update(directory: repoRoot, workspaceId: workspaceId, isRemote: false, isActive: true)
        await waitUntil("ready") { store.state == .ready(url: page.url) }
        XCTAssertEqual(producer.callCount, 1)
        await waitUntil("watching") { store.isWatching }
        store.update(directory: repoRoot, workspaceId: workspaceId, isRemote: false, isActive: true)
        XCTAssertEqual(producer.callCount, 1, "re-syncing an active panel does not regenerate")
    }

    func testWatchStartsOnlyWhileVisibleInChangesModeAndStopsWhenHidden() async throws {
        let page = try makePage(reloadable: true)
        let producer = ScriptedChangesPageProducer(pages: [page])
        let watchSource = ScriptedRepositoryWatchSource()
        let store = makeStore(producer: producer, watchSource: watchSource)
        let workspaceId = UUID()

        store.update(directory: repoRoot, workspaceId: workspaceId, isRemote: false, isActive: true)
        await waitUntil("ready") { store.state == .ready(url: page.url) }
        await waitUntil("watching") { store.isWatching }
        XCTAssertEqual(watchSource.startedRepoRoots, [repoRoot])

        store.update(directory: repoRoot, workspaceId: workspaceId, isRemote: false, isActive: false)
        XCTAssertFalse(store.isWatching, "a hidden panel must not watch the repository")
        await waitUntil("watch torn down") { watchSource.stoppedRepoRoots == [self.repoRoot] }
        XCTAssertEqual(store.state, .ready(url: page.url), "hiding keeps the page for the next show")

        store.update(directory: repoRoot, workspaceId: workspaceId, isRemote: false, isActive: true)
        await waitUntil("watching again") { store.isWatching }
        XCTAssertEqual(watchSource.startedRepoRoots, [repoRoot, repoRoot])
        XCTAssertEqual(store.state, .ready(url: page.url), "showing the panel again reuses the page")
        XCTAssertEqual(producer.callCount, 1)

        store.stop()
        XCTAssertFalse(store.isWatching)
        await waitUntil("stopped") { watchSource.stoppedRepoRoots.count == 2 }
    }

    func testRepositoryEventsReloadReloadablePagesInPlace() async throws {
        let page = try makePage(reloadable: true)
        let producer = ScriptedChangesPageProducer(pages: [page])
        let watchSource = ScriptedRepositoryWatchSource()
        let store = makeStore(producer: producer, watchSource: watchSource)
        store.update(directory: repoRoot, workspaceId: UUID(), isRemote: false, isActive: true)
        await waitUntil("ready") { store.state == .ready(url: page.url) }
        await waitUntil("watching") { store.isWatching }

        // The git-aware watch already coalesces a burst into one event.
        watchSource.fire(repoRoot: repoRoot)
        await waitUntil("reloaded") { store.reloadGeneration == 1 }
        XCTAssertEqual(producer.callCount, 1, "reloadable pages reload in place instead of regenerating")

        watchSource.fire(repoRoot: repoRoot)
        await waitUntil("reloaded again") { store.reloadGeneration == 2 }

        store.stop()
        store.handleRepositoryChange()
        XCTAssertEqual(store.reloadGeneration, 2, "a stopped store ignores changes")
    }

    func testStaticPagesRegenerateInsteadOfReloading() async throws {
        let first = try makePage(reloadable: false)
        let second = try makePage(reloadable: false)
        let producer = ScriptedChangesPageProducer(pages: [first, second])
        let watchSource = ScriptedRepositoryWatchSource()
        let handler = CmuxDiffViewerURLSchemeHandler()
        let store = makeStore(producer: producer, watchSource: watchSource, handler: handler)
        store.update(directory: repoRoot, workspaceId: UUID(), isRemote: false, isActive: true)
        await waitUntil("ready") { store.state == .ready(url: first.url) }

        store.handleRepositoryChange()
        XCTAssertEqual(store.state, .ready(url: first.url), "the current document stays up while the replacement renders")
        await waitUntil("swapped") { store.state == .ready(url: second.url) }
        XCTAssertEqual(producer.callCount, 2, "one event, one regeneration")
        XCTAssertEqual(store.reloadGeneration, 0, "static pages never ask the web view to reload")
        XCTAssertTrue(handler.hasActiveSession(token: second.token))
    }

    func testReactivationRefreshesThePageAndForgetsNegativeRepoProbes() async throws {
        let reloadable = try makePage(reloadable: true)
        let producer = ScriptedChangesPageProducer(pages: [reloadable])
        let watchSource = ScriptedRepositoryWatchSource()
        let store = makeStore(producer: producer, watchSource: watchSource)
        let workspaceId = UUID()

        store.update(directory: repoRoot, workspaceId: workspaceId, isRemote: false, isActive: true)
        await waitUntil("ready") { store.state == .ready(url: reloadable.url) }
        XCTAssertEqual(store.reloadGeneration, 0)

        // Edits made while hidden were not watched, so showing the panel
        // again refreshes the document it kept.
        store.update(directory: repoRoot, workspaceId: workspaceId, isRemote: false, isActive: false)
        store.update(directory: repoRoot, workspaceId: workspaceId, isRemote: false, isActive: true)
        XCTAssertEqual(store.reloadGeneration, 1, "reloadable pages reload on reactivation")
        XCTAssertEqual(producer.callCount, 1)

        // Static pages regenerate instead.
        let firstStatic = try makePage(reloadable: false)
        let secondStatic = try makePage(reloadable: false)
        let staticProducer = ScriptedChangesPageProducer(pages: [firstStatic, secondStatic])
        let staticStore = makeStore(producer: staticProducer, watchSource: ScriptedRepositoryWatchSource())
        staticStore.update(directory: repoRoot, workspaceId: workspaceId, isRemote: false, isActive: true)
        await waitUntil("static ready") { staticStore.state == .ready(url: firstStatic.url) }
        staticStore.update(directory: repoRoot, workspaceId: workspaceId, isRemote: false, isActive: false)
        staticStore.update(directory: repoRoot, workspaceId: workspaceId, isRemote: false, isActive: true)
        await waitUntil("static regenerated") { staticStore.state == .ready(url: secondStatic.url) }
        XCTAssertEqual(staticProducer.callCount, 2)
        XCTAssertEqual(staticStore.reloadGeneration, 0)

        // `git init` after the first probe: a directory cached as "not a
        // repository" is probed again when the panel becomes active.
        let probes = ProbeCounter()
        let probedStore = makeStore(
            producer: ScriptedChangesPageProducer(pages: [reloadable]),
            watchSource: ScriptedRepositoryWatchSource(),
            repoRootResolver: { [probes] directory in
                probes.increment()
                return probes.isRepository ? directory : nil
            }
        )
        let plain = "/tmp/cmux-changes-tests/plain"
        probedStore.update(directory: plain, workspaceId: workspaceId, isRemote: false, isActive: true)
        await waitUntil("not a repository") { probedStore.state == .notARepository(path: plain) }
        probedStore.update(directory: plain, workspaceId: workspaceId, isRemote: false, isActive: true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(probes.count, 1, "a negative answer is cached while the panel stays active")

        probes.isRepository = true
        probedStore.update(directory: plain, workspaceId: workspaceId, isRemote: false, isActive: false)
        probedStore.update(directory: plain, workspaceId: workspaceId, isRemote: false, isActive: true)
        await waitUntil("now a repository") { probedStore.state == .ready(url: reloadable.url) }
        XCTAssertEqual(probes.count, 2, "reactivation probes the directory again")
    }

    func testSwitchingRepositoriesKeepsThePreviousDocumentWhileLoading() async throws {
        let first = try makePage(reloadable: true)
        let second = try makePage(reloadable: true)
        let producer = ScriptedChangesPageProducer(pages: [first, second])
        let watchSource = ScriptedRepositoryWatchSource()
        let store = makeStore(producer: producer, watchSource: watchSource)
        let workspaceId = UUID()

        store.update(directory: repoRoot, workspaceId: workspaceId, isRemote: false, isActive: true)
        await waitUntil("ready") { store.state == .ready(url: first.url) }

        store.update(directory: otherRepoRoot, workspaceId: workspaceId, isRemote: false, isActive: true)
        await waitUntil("loading with the previous document") {
            store.state == .loading(previousURL: first.url) || store.state == .ready(url: second.url)
        }
        await waitUntil("second ready") { store.state == .ready(url: second.url) }
        XCTAssertEqual(store.target, RightSidebarChangesTarget(workspaceId: workspaceId, repoRoot: otherRepoRoot))
        await waitUntil("watching the new repository") { watchSource.startedRepoRoots == [self.repoRoot, self.otherRepoRoot] }
        await waitUntil("old watch stopped") { watchSource.stoppedRepoRoots == [self.repoRoot] }
    }

    func testDecodePageIsStrictAboutTheVerbContract() throws {
        let entryURL = FileManager.default.temporaryDirectory.appendingPathComponent("index.html")
        let valid: [String: Any] = [
            "url": "cmux-diff-viewer://0123456789abcdef/index.html",
            "allowed_files": [["request_path": "/index.html", "file_path": entryURL.path, "mime_type": "text/html"]],
            "reloadable": true,
        ]
        let page = try RightSidebarChangesProcessRunner.decodePage(from: JSONSerialization.data(withJSONObject: valid))
        XCTAssertEqual(page.token, "0123456789abcdef", "the token is the URL host")
        XCTAssertTrue(page.reloadable)
        XCTAssertEqual(page.allowedFiles.map(\.requestPath), ["/index.html"])

        XCTAssertThrowsError(try RightSidebarChangesProcessRunner.decodePage(from: Data("garbage {\"url\": 1}".utf8)))
        var missingFiles = valid
        missingFiles["allowed_files"] = [[String: Any]]()
        XCTAssertThrowsError(try RightSidebarChangesProcessRunner.decodePage(from: JSONSerialization.data(withJSONObject: missingFiles)))
        var badToken = valid
        badToken["url"] = "cmux-diff-viewer://not a token/index.html"
        XCTAssertThrowsError(try RightSidebarChangesProcessRunner.decodePage(from: JSONSerialization.data(withJSONObject: badToken)))
    }
}

/// Counts repository probes and lets a test flip the answer (`git init`).
private final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var countStorage = 0
    private var isRepositoryStorage = false

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return countStorage
    }

    var isRepository: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isRepositoryStorage }
        set { lock.lock(); isRepositoryStorage = newValue; lock.unlock() }
    }

    func increment() {
        lock.lock(); countStorage += 1; lock.unlock()
    }
}
