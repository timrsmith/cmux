import CmuxBrowser
import CmuxFoundation
import Foundation
import WebKit
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

/// Answers the store's working-tree digest requests. By default every call
/// returns a fresh value, so each repository event reads as a change; a test
/// pins a value (or `nil`) to exercise the gate, and may hold answers behind
/// a gate to observe how events fold while a digest is in flight.
final class ScriptedFingerprintSource: @unchecked Sendable {
    private let lock = NSLock()
    private var pinned: String??
    private var counter = 0
    private var callCountStorage = 0
    private var gateStorage: ProbeGate?

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return callCountStorage
    }

    /// Every later answer is `value` (pass `nil` for an unobtainable digest).
    func pin(_ value: String?) {
        lock.lock(); pinned = .some(value); lock.unlock()
    }

    func hold(behind gate: ProbeGate) {
        lock.lock(); gateStorage = gate; lock.unlock()
    }

    var producer: RightSidebarChangesFingerprint.Producer {
        { [self] _ in await self.next() }
    }

    private func next() async -> String? {
        lock.lock()
        let gate = gateStorage
        lock.unlock()
        if let gate { await gate.wait() }
        lock.lock(); defer { lock.unlock() }
        callCountStorage += 1
        if let pinned { return pinned }
        counter += 1
        return "fingerprint-\(counter)"
    }
}

/// A producer that blocks until released, so a test can observe what the
/// store does while a load is pending, and whether the load was cancelled.
final class GatedChangesPageProducer: @unchecked Sendable {
    private let lock = NSLock()
    private var releasedStorage = false
    private var startedStorage = 0
    private var cancelledStorage = 0
    let page: RightSidebarChangesPage

    init(page: RightSidebarChangesPage) {
        self.page = page
    }

    var startedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return startedStorage
    }

    var cancelledCount: Int {
        lock.lock(); defer { lock.unlock() }
        return cancelledStorage
    }

    private var isReleased: Bool {
        lock.lock(); defer { lock.unlock() }
        return releasedStorage
    }

    func release() {
        lock.lock(); releasedStorage = true; lock.unlock()
    }

    func produce() async throws -> RightSidebarChangesPage {
        lock.lock(); startedStorage += 1; lock.unlock()
        do {
            while !isReleased {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        } catch is CancellationError {
            lock.lock(); cancelledStorage += 1; lock.unlock()
            throw CancellationError()
        }
        return page
    }
}

/// Holds an async fake open until the test lets it answer; never observes
/// cancellation, so it also stands in for a producer that ignores it.
final class ProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false

    func open() {
        lock.lock(); isOpen = true; lock.unlock()
    }

    func wait() async {
        while true {
            lock.lock()
            let open = isOpen
            lock.unlock()
            if open { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
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
        repoRootResolver: RightSidebarChangesStore.RepoRootResolver? = nil,
        fingerprints: ScriptedFingerprintSource = ScriptedFingerprintSource()
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
            schemeHandler: handler,
            fingerprintProducer: fingerprints.producer
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

    /// Other worktrees' commits and fetches write the shared `.git` directory
    /// without touching this working tree's diff; the digest keeps those
    /// events from reloading the page.
    func testEventsThatLeaveTheWorkingTreeDigestUnchangedDoNotReload() async throws {
        let page = try makePage(reloadable: true)
        let producer = ScriptedChangesPageProducer(pages: [page])
        let watchSource = ScriptedRepositoryWatchSource()
        let fingerprints = ScriptedFingerprintSource()
        fingerprints.pin("clean")
        let store = makeStore(producer: producer, watchSource: watchSource, fingerprints: fingerprints)
        store.update(directory: repoRoot, workspaceId: UUID(), isRemote: false, isActive: true)
        await waitUntil("ready") { store.state == .ready(url: page.url) }
        await waitUntil("seeded") { store.fingerprintCheckCount == 1 }
        await waitUntil("watching") { store.isWatching }

        watchSource.fire(repoRoot: repoRoot)
        await waitUntil("checked") { store.fingerprintCheckCount == 2 }
        XCTAssertEqual(store.reloadGeneration, 0, "an unchanged digest is not a change")

        fingerprints.pin("edited")
        watchSource.fire(repoRoot: repoRoot)
        await waitUntil("reloaded") { store.reloadGeneration == 1 }
        // The digest that triggered the reload is the document's; no re-seed.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.fingerprintCheckCount, 3)
        XCTAssertEqual(producer.callCount, 1)

        // The same digest again is not a change.
        watchSource.fire(repoRoot: repoRoot)
        await waitUntil("checked again") { store.fingerprintCheckCount == 4 }
        XCTAssertEqual(store.reloadGeneration, 1)
    }

    func testAnUnobtainableDigestRefreshesConservatively() async throws {
        let page = try makePage(reloadable: true)
        let producer = ScriptedChangesPageProducer(pages: [page])
        let watchSource = ScriptedRepositoryWatchSource()
        let fingerprints = ScriptedFingerprintSource()
        fingerprints.pin(nil)
        let store = makeStore(producer: producer, watchSource: watchSource, fingerprints: fingerprints)
        store.update(directory: repoRoot, workspaceId: UUID(), isRemote: false, isActive: true)
        await waitUntil("ready") { store.state == .ready(url: page.url) }
        await waitUntil("seeded") { store.fingerprintCheckCount == 1 }
        await waitUntil("watching") { store.isWatching }

        watchSource.fire(repoRoot: repoRoot)
        await waitUntil("reloaded") { store.reloadGeneration == 1 }
    }

    /// A burst of events while a digest is running costs one more digest, not
    /// one per event, and at most one refresh.
    func testEventsDuringADigestFoldIntoOneRecheck() async throws {
        let page = try makePage(reloadable: true)
        let producer = ScriptedChangesPageProducer(pages: [page])
        let watchSource = ScriptedRepositoryWatchSource()
        let fingerprints = ScriptedFingerprintSource()
        let gate = ProbeGate()
        fingerprints.hold(behind: gate)
        let store = makeStore(producer: producer, watchSource: watchSource, fingerprints: fingerprints)
        store.update(directory: repoRoot, workspaceId: UUID(), isRemote: false, isActive: true)
        await waitUntil("ready") { store.state == .ready(url: page.url) }
        await waitUntil("watching") { store.isWatching }
        XCTAssertEqual(store.fingerprintCheckCount, 0, "the seed is still held")

        for _ in 0..<3 {
            watchSource.fire(repoRoot: repoRoot)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        gate.open()
        // Seed, then one folded re-check (a fresh value, so a reload) whose
        // digest is kept for the reloaded document.
        await waitUntil("reloaded once") { store.reloadGeneration == 1 }
        await waitUntil("settled") { store.fingerprintCheckCount == 2 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.reloadGeneration, 1)
        XCTAssertEqual(store.fingerprintCheckCount, 2)
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

        // `git init` after the first probe: "not a repository" is never
        // cached, so the very next sync for the directory sees the repository
        // even while the panel stays visible.
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
        XCTAssertEqual(probes.count, 1)
        probedStore.update(directory: plain, workspaceId: workspaceId, isRemote: false, isActive: true)
        await waitUntil("probed again") { probes.count == 2 }
        XCTAssertEqual(probedStore.state, .notARepository(path: plain), "a repeated negative keeps the placeholder")

        probes.isRepository = true
        probedStore.update(directory: plain, workspaceId: workspaceId, isRemote: false, isActive: true)
        await waitUntil("now a repository") { probedStore.state == .ready(url: reloadable.url) }
        XCTAssertEqual(probes.count, 3, "each sync of a non-repository directory probes it again")

        // The positive answer is cached: the same directory does not probe again.
        probedStore.update(directory: plain, workspaceId: workspaceId, isRemote: false, isActive: true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(probes.count, 3)
        XCTAssertEqual(probedStore.cachedRepoRootDirectories, [plain])
    }

    func testRepeatedSyncsShareOneInFlightProbeAndThePositiveCacheIsBounded() async throws {
        let page = try makePage(reloadable: true)
        let probes = ProbeCounter()
        let gate = ProbeGate()
        let store = makeStore(
            producer: ScriptedChangesPageProducer(pages: [page]),
            watchSource: ScriptedRepositoryWatchSource(),
            repoRootResolver: { [probes, gate] _ in
                probes.increment()
                await gate.wait()
                return nil
            }
        )
        let workspaceId = UUID()
        let plain = "/tmp/cmux-changes-tests/plain"
        // A burst of syncs for one directory waits for the single probe in flight.
        store.update(directory: plain, workspaceId: workspaceId, isRemote: false, isActive: true)
        store.update(directory: plain, workspaceId: workspaceId, isRemote: false, isActive: true)
        store.update(directory: plain, workspaceId: workspaceId, isRemote: false, isActive: true)
        await waitUntil("probe started") { probes.count == 1 }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(probes.count, 1, "identical syncs do not stack probes")
        gate.open()
        await waitUntil("not a repository") { store.state == .notARepository(path: plain) }

        // Positive answers are kept for the most recent 64 directories.
        let cached = makeStore(
            producer: ScriptedChangesPageProducer(pages: [page]),
            watchSource: ScriptedRepositoryWatchSource(),
            repoRootResolver: { directory in directory }
        )
        let limit = RightSidebarChangesStore.repoRootCacheLimit
        for index in 0...limit {
            let directory = "/tmp/cmux-changes-tests/many/\(index)"
            cached.update(directory: directory, workspaceId: workspaceId, isRemote: false, isActive: false)
            await waitUntil("cached \(index)") { cached.cachedRepoRootDirectories.last == directory }
        }
        XCTAssertEqual(cached.cachedRepoRootDirectories.count, limit)
        XCTAssertEqual(cached.cachedRepoRootDirectories.first, "/tmp/cmux-changes-tests/many/1", "the oldest entry is dropped")
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

    func testSameRepositoryWorkspaceSwitchKeepsThePendingLoad() async throws {
        let page = try makePage(reloadable: true)
        let producer = GatedChangesPageProducer(page: page)
        let watchSource = ScriptedRepositoryWatchSource()
        let handler = CmuxDiffViewerURLSchemeHandler()
        let repoRoot = repoRoot
        let store = RightSidebarChangesStore(
            repoRootResolver: { _ in repoRoot },
            pageProducer: { _, _ in try await producer.produce() },
            watchFactory: watchSource.factory,
            schemeHandler: handler
        )
        let firstWorkspace = UUID()
        let secondWorkspace = UUID()

        store.update(directory: repoRoot, workspaceId: firstWorkspace, isRemote: false, isActive: true)
        await waitUntil("producing") { producer.startedCount == 1 }
        XCTAssertEqual(store.state, .loading(previousURL: nil))

        // The same repository under another workspace keeps the load...
        store.update(directory: repoRoot + "/Sources", workspaceId: secondWorkspace, isRemote: false, isActive: true)
        await waitUntil("retargeted") { store.target?.workspaceId == secondWorkspace }
        XCTAssertEqual(store.state, .loading(previousURL: nil))
        XCTAssertEqual(producer.startedCount, 1, "a same-repository switch does not restart production")

        // ...and its result lands for the retargeted panel instead of being dropped.
        producer.release()
        await waitUntil("ready") { store.state == .ready(url: page.url) }
        XCTAssertEqual(producer.cancelledCount, 0)
        XCTAssertTrue(handler.hasActiveSession(token: page.token))
        XCTAssertEqual(store.target, RightSidebarChangesTarget(workspaceId: secondWorkspace, repoRoot: repoRoot))
    }

    func testProducerFailureLandsAfterASameRepositoryWorkspaceSwitch() async throws {
        struct ProducerError: LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let gate = ProbeGate()
        let watchSource = ScriptedRepositoryWatchSource()
        let repoRoot = repoRoot
        let store = RightSidebarChangesStore(
            repoRootResolver: { _ in repoRoot },
            pageProducer: { _, _ in
                await gate.wait()
                throw ProducerError()
            },
            watchFactory: watchSource.factory,
            schemeHandler: CmuxDiffViewerURLSchemeHandler()
        )
        store.update(directory: repoRoot, workspaceId: UUID(), isRemote: false, isActive: true)
        let secondWorkspace = UUID()
        store.update(directory: repoRoot, workspaceId: secondWorkspace, isRemote: false, isActive: true)
        await waitUntil("retargeted") { store.target?.workspaceId == secondWorkspace }
        gate.open()
        await waitUntil("failed") { store.state == .failed(message: "boom") }
    }

    func testSwitchingToAnotherRepositoryCancelsTheSlowProducer() async throws {
        let slow = try makePage(reloadable: true)
        let other = try makePage(reloadable: true)
        let slowProducer = GatedChangesPageProducer(page: slow)
        let otherProducer = ScriptedChangesPageProducer(pages: [other])
        let watchSource = ScriptedRepositoryWatchSource()
        let handler = CmuxDiffViewerURLSchemeHandler()
        let repoRoot = repoRoot
        let otherRepoRoot = otherRepoRoot
        let store = RightSidebarChangesStore(
            repoRootResolver: { directory in directory },
            pageProducer: { target, _ in
                if target.repoRoot == repoRoot {
                    return try await slowProducer.produce()
                }
                return otherProducer.produce()
            },
            watchFactory: watchSource.factory,
            schemeHandler: handler
        )
        let workspaceId = UUID()
        store.update(directory: repoRoot, workspaceId: workspaceId, isRemote: false, isActive: true)
        await waitUntil("producing") { slowProducer.startedCount == 1 }

        store.update(directory: otherRepoRoot, workspaceId: workspaceId, isRemote: false, isActive: true)
        await waitUntil("slow producer cancelled") { slowProducer.cancelledCount == 1 }
        await waitUntil("other ready") { store.state == .ready(url: other.url) }

        // A late result from the cancelled load never registers a session.
        slowProducer.release()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.state, .ready(url: other.url))
        XCTAssertFalse(handler.hasActiveSession(token: slow.token))
    }

    func testProductionTimesOutIntoAFailure() async throws {
        let page = try makePage(reloadable: true)
        let producer = GatedChangesPageProducer(page: page)
        let watchSource = ScriptedRepositoryWatchSource()
        let handler = CmuxDiffViewerURLSchemeHandler()
        let repoRoot = repoRoot
        let store = RightSidebarChangesStore(
            repoRootResolver: { _ in repoRoot },
            pageProducer: { _, _ in try await producer.produce() },
            watchFactory: watchSource.factory,
            schemeHandler: handler,
            productionTimeout: 0.2
        )
        store.update(directory: repoRoot, workspaceId: UUID(), isRemote: false, isActive: true)
        let expected = try XCTUnwrap(RightSidebarChangesProductionRace.Timeout().errorDescription)
        XCTAssertFalse(expected.isEmpty)
        await waitUntil("timed out") { store.state == .failed(message: expected) }
        await waitUntil("producer cancelled") { producer.cancelledCount == 1 }
        XCTAssertFalse(handler.hasActiveSession(token: page.token))

        // A producer that ignores cancellation is abandoned, not awaited.
        let stuck = ProbeGate()
        let stuckStore = RightSidebarChangesStore(
            repoRootResolver: { _ in repoRoot },
            pageProducer: { _, _ in
                await stuck.wait()
                return page
            },
            watchFactory: watchSource.factory,
            schemeHandler: handler,
            productionTimeout: 0.2
        )
        stuckStore.update(directory: repoRoot, workspaceId: UUID(), isRemote: false, isActive: true)
        await waitUntil("timed out despite the stuck producer") { stuckStore.state == .failed(message: expected) }
        stuck.open()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(stuckStore.state, .failed(message: expected), "the abandoned result is dropped")
        XCTAssertFalse(handler.hasActiveSession(token: page.token))
    }

    func testReplacedPagesAndStopUnregisterTheirSessions() async throws {
        let first = try makePage(reloadable: false)
        let second = try makePage(reloadable: false)
        let producer = ScriptedChangesPageProducer(pages: [first, second])
        let watchSource = ScriptedRepositoryWatchSource()
        let handler = CmuxDiffViewerURLSchemeHandler()
        let store = makeStore(producer: producer, watchSource: watchSource, handler: handler)
        store.update(directory: repoRoot, workspaceId: UUID(), isRemote: false, isActive: true)
        await waitUntil("ready") { store.state == .ready(url: first.url) }
        XCTAssertTrue(handler.hasActiveSession(token: first.token))

        // A static regeneration replaces the page and drops the old session.
        store.handleRepositoryChange()
        await waitUntil("swapped") { store.state == .ready(url: second.url) }
        XCTAssertTrue(handler.hasActiveSession(token: second.token))
        XCTAssertFalse(handler.hasActiveSession(token: first.token), "exactly one session stays registered")

        // Window teardown: nothing displays the page any more.
        store.stop()
        XCTAssertFalse(handler.hasActiveSession(token: second.token))
        XCTAssertNil(store.page)
        XCTAssertTrue(store.recentPageRepoRoots.isEmpty)
    }

    func testReturningToARecentRepositoryReusesItsPage() async throws {
        let page = try makePage(reloadable: true)
        let producer = ScriptedChangesPageProducer(pages: [page])
        let watchSource = ScriptedRepositoryWatchSource()
        let handler = CmuxDiffViewerURLSchemeHandler()
        let store = makeStore(producer: producer, watchSource: watchSource, handler: handler)
        let workspaceId = UUID()

        store.update(directory: repoRoot, workspaceId: workspaceId, isRemote: false, isActive: true)
        await waitUntil("ready") { store.state == .ready(url: page.url) }
        XCTAssertEqual(producer.callCount, 1)

        let plain = "/tmp/cmux-changes-tests/plain"
        store.update(directory: plain, workspaceId: workspaceId, isRemote: false, isActive: true)
        await waitUntil("not a repository") { store.state == .notARepository(path: plain) }
        XCTAssertNil(store.page)
        XCTAssertTrue(handler.hasActiveSession(token: page.token), "a kept page keeps its session")

        // Back to the repository: the kept page shows at once and refreshes,
        // because edits made while it was not watched went unseen.
        store.update(directory: repoRoot, workspaceId: workspaceId, isRemote: false, isActive: true)
        await waitUntil("ready again") { store.state == .ready(url: page.url) }
        XCTAssertEqual(producer.callCount, 1, "returning to a recent repository does not spawn the CLI again")
        XCTAssertEqual(store.reloadGeneration, 1)
        XCTAssertEqual(store.recentPageRepoRoots, [repoRoot])
    }

    func testRecentPagesAreBoundedAndEvictionUnregistersTheOldest() async throws {
        let limit = RightSidebarChangesStore.recentPageLimit
        var pages: [RightSidebarChangesPage] = []
        for _ in 0...limit { pages.append(try makePage(reloadable: true)) }
        let producer = ScriptedChangesPageProducer(pages: pages)
        let watchSource = ScriptedRepositoryWatchSource()
        let handler = CmuxDiffViewerURLSchemeHandler()
        let store = RightSidebarChangesStore(
            repoRootResolver: { directory in directory },
            pageProducer: { _, _ in producer.produce() },
            watchFactory: watchSource.factory,
            schemeHandler: handler
        )
        let workspaceId = UUID()
        for (index, page) in pages.enumerated() {
            store.update(directory: "/tmp/cmux-changes-tests/lru/\(index)", workspaceId: workspaceId, isRemote: false, isActive: true)
            await waitUntil("ready \(index)") { store.state == .ready(url: page.url) }
        }
        XCTAssertEqual(store.recentPageRepoRoots.count, limit)
        XCTAssertEqual(store.recentPageRepoRoots.first, "/tmp/cmux-changes-tests/lru/1")
        XCTAssertFalse(handler.hasActiveSession(token: pages[0].token), "the evicted page's session is dropped")
        for page in pages.dropFirst() {
            XCTAssertTrue(handler.hasActiveSession(token: page.token))
        }

        // The evicted repository is produced again on return.
        store.update(directory: "/tmp/cmux-changes-tests/lru/0", workspaceId: workspaceId, isRemote: false, isActive: true)
        await waitUntil("re-produced") { producer.callCount == limit + 2 }
    }

    func testFailureMessageNeverSurfacesTheChildOutput() {
        let message = RightSidebarChangesProcessRunner.failureMessage(
            stderr: "fatal: not a repository: /Users/someone/secret\n",
            stdout: "{\"partial\": true}",
            status: 128
        )
        XCTAssertFalse(message.contains("secret"))
        XCTAssertFalse(message.contains("partial"))
        XCTAssertTrue(message.contains("128"), "the exit status is the only detail, got \(message)")
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

// MARK: - Navigation policy

final class RightSidebarChangesNavigationPolicyTests: XCTestCase {
    private let token = "0123456789abcdef"
    private let registered: Set<String> = [
        "cmux-diff-viewer://0123456789abcdef/index.html",
        "cmux-diff-viewer://0123456789abcdef/diff-session-1.patch",
    ]

    private func decide(
        _ raw: String,
        navigationType: WKNavigationType = .other,
        isMainFrame: Bool = true,
        token: String? = "0123456789abcdef"
    ) -> RightSidebarChangesNavigationPolicy.Decision {
        RightSidebarChangesNavigationPolicy.decision(
            for: URL(string: raw),
            navigationType: navigationType,
            isMainFrame: isMainFrame,
            token: token,
            isRegistered: { [registered] in registered.contains($0.absoluteString) }
        )
    }

    func testRegisteredPagesOfTheCurrentTokenLoad() {
        XCTAssertEqual(decide("cmux-diff-viewer://0123456789abcdef/index.html"), .allow)
        XCTAssertEqual(decide("cmux-diff-viewer://0123456789abcdef/diff-session-1.patch", isMainFrame: false), .allow)
        XCTAssertEqual(decide("about:blank"), .allow)
        // The base picker's regeneration route is token-scoped and validated by the handler.
        XCTAssertEqual(
            decide("cmux-diff-viewer://0123456789abcdef/__cmux_diff_viewer_branch?group=g&repo=%2Ftmp%2Fr&base=main"),
            .allow
        )
    }

    func testEverythingElseIsCancelled() {
        XCTAssertEqual(decide("cmux-diff-viewer://0123456789abcdef/other.html"), .cancel, "unregistered file")
        XCTAssertEqual(decide("cmux-diff-viewer://fedcba9876543210/index.html"), .cancel, "another session's token")
        XCTAssertEqual(decide("cmux-diff-viewer://0123456789abcdef/index.html", token: nil), .cancel, "no page hosted yet")
        XCTAssertEqual(
            decide("cmux-diff-viewer://0123456789abcdef/__cmux_diff_viewer_branch?group=g", isMainFrame: false),
            .cancel,
            "the branch route only navigates the document itself"
        )
        XCTAssertEqual(decide("cmux-diff-viewer://0123456789abcdef/__cmux_diff_viewer_branch"), .cancel, "route without a query")
        XCTAssertEqual(decide("https://example.com/"), .cancel, "scripted redirect")
        XCTAssertEqual(decide("https://example.com/", navigationType: .linkActivated, isMainFrame: false), .cancel, "framed link")
        XCTAssertEqual(decide("http://127.0.0.1:1234/tok/index.html#cmux-diff-viewer"), .cancel, "local HTTP viewer form")
        XCTAssertEqual(decide("file:///etc/passwd", navigationType: .linkActivated), .cancel)
        XCTAssertEqual(decide("javascript:alert(1)", navigationType: .linkActivated), .cancel)
        XCTAssertEqual(decide("mailto:someone@example.com", navigationType: .linkActivated), .cancel)
        XCTAssertEqual(decide("not a url"), .cancel)
        XCTAssertEqual(RightSidebarChangesNavigationPolicy.decision(
            for: nil, navigationType: .other, isMainFrame: true, token: token, isRegistered: { _ in true }
        ), .cancel)
    }

    func testActivatedWebLinksOpenInTheSystemBrowser() {
        XCTAssertEqual(decide("https://github.com/manaflow-ai/cmux/pull/1", navigationType: .linkActivated), .openExternally)
        XCTAssertEqual(decide("http://example.com/", navigationType: .linkActivated), .openExternally)
    }

    func testPopupsOnlyEverOpenWebURLsExternally() {
        XCTAssertEqual(RightSidebarChangesNavigationPolicy.popupDecision(for: URL(string: "https://example.com/")), .openExternally)
        XCTAssertEqual(RightSidebarChangesNavigationPolicy.popupDecision(for: URL(string: "cmux-diff-viewer://0123456789abcdef/index.html")), .cancel)
        XCTAssertEqual(RightSidebarChangesNavigationPolicy.popupDecision(for: URL(string: "file:///tmp/x")), .cancel)
        XCTAssertEqual(RightSidebarChangesNavigationPolicy.popupDecision(for: nil), .cancel)
    }
}
