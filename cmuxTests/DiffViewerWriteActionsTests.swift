import CmuxBrowser
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Admission policy for the `cmuxDiff` bridge and the scheme handler's session
/// patch refresh, which together let the diff viewer's write actions reach the
/// Rust sidecar only from the frame and panel that own the session.
@MainActor
@Suite(.serialized)
struct DiffViewerWriteActionsTests {
    private let frameToken = "0123456789abcdef"

    private func body(
        _ method: String,
        token: String? = "0123456789abcdef",
        params extra: [String: Any] = [:]
    ) -> [String: Any] {
        var params = extra
        if let token {
            params["capabilityToken"] = token
        }
        var body: [String: Any] = ["id": "request", "version": 1, "method": method]
        if !params.isEmpty {
            body["params"] = params
        }
        return body
    }

    /// `rejection(for:frameToken:panelAssociated:)` with a constant association.
    private func rejection(
        _ body: [String: Any],
        frameToken: String?,
        panelAssociated: Bool
    ) -> DiffSidecarRequestPolicy.Rejection? {
        DiffSidecarRequestPolicy.rejection(for: body, frameToken: frameToken) { panelAssociated }
    }

    @Test
    func policyForwardsOnlyTheKnownProtocolMethods() {
        #expect(rejection(body("protocolHandshake", token: nil), frameToken: frameToken, panelAssociated: false) == nil)
        // The repository status query reads (Git and the forge CLI) without
        // changing anything, so it needs the token but no association.
        for method in ["sessionOpen", "sessionClose", "branchList", "branchChange", "worktreeRepositoryStatus"] {
            #expect(
                rejection(body(method), frameToken: frameToken, panelAssociated: false) == nil,
                "\(method) is a read method"
            )
        }
        for method in ["surface.respawn", "worktreeRunCommand", "", "sessionopen", "hostOpenfile", "hostRunCommand"] {
            #expect(
                rejection(body(method), frameToken: frameToken, panelAssociated: true) == .unknownMethod,
                "\(method) is not forwarded"
            )
        }
        #expect(rejection(["id": "request", "version": 1], frameToken: frameToken, panelAssociated: true) == .unknownMethod)
        #expect(DiffSidecarRequestPolicy.readMethods.isDisjoint(with: DiffSidecarRequestPolicy.writeMethods))
        #expect(DiffSidecarRequestPolicy.readMethods.isDisjoint(with: DiffSidecarRequestPolicy.hostMethods))
        #expect(DiffSidecarRequestPolicy.writeMethods.isDisjoint(with: DiffSidecarRequestPolicy.hostMethods))
    }

    /// Every sidecar method that mutates the repository or its remote is a
    /// write; the host action is gated the same way; the status query is not.
    @Test
    func newMethodsAreClassifiedAsWritesReadsOrHostActions() {
        for method in ["worktreeDiscardAll", "worktreeStageAll", "worktreeUnstageAll", "worktreePush", "worktreeCreatePullRequest"] {
            #expect(DiffSidecarRequestPolicy.writeMethods.contains(method), "\(method) is a write")
        }
        for method in ["worktreeStageFiles", "worktreeUnstageFiles", "worktreeDiscardFiles"] {
            #expect(DiffSidecarRequestPolicy.writeMethods.contains(method), "\(method) is a selection write")
        }
        #expect(DiffSidecarRequestPolicy.readMethods.contains("worktreeRepositoryStatus"))
        #expect(DiffSidecarRequestPolicy.hostMethods == ["hostOpenFile"])
        let open = body("hostOpenFile", params: ["path": "src/main.swift"])
        #expect(rejection(open, frameToken: frameToken, panelAssociated: true) == nil)
        #expect(rejection(open, frameToken: frameToken, panelAssociated: false) == .unassociatedPanel)
        #expect(rejection(body("hostOpenFile", token: "fedcba9876543210", params: ["path": "a"]), frameToken: frameToken, panelAssociated: true) == .tokenMismatch)
        #expect(rejection(body("hostOpenFile", token: nil, params: ["path": "a"]), frameToken: frameToken, panelAssociated: true) == .tokenMismatch)
    }

    /// The host action gate: repository-relative paths only, resolved inside a
    /// repository the token's allow-list names, to an existing regular file.
    @Test
    func hostOpenFileResolvesOnlyAllowlistedRepositoryFiles() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-host-actions-\(UUID().uuidString)", isDirectory: true)
        let trustedRoot = fixture.appendingPathComponent("trusted", isDirectory: true)
        let repo = fixture.appendingPathComponent("repo", isDirectory: true)
        let other = fixture.appendingPathComponent("other", isDirectory: true)
        let outside = fixture.appendingPathComponent("outside", isDirectory: true)
        for directory in [trustedRoot, repo.appendingPathComponent("src"), other, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: fixture) }
        try "print()".write(to: repo.appendingPathComponent("src/main.swift"), atomically: true, encoding: .utf8)
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try "other".write(to: other.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        // A symlink inside the repository that points out of it.
        try FileManager.default.createSymbolicLink(
            at: repo.appendingPathComponent("escape"),
            withDestinationURL: outside
        )
        let otherToken = "fedcba9876543210"
        for (group, token, roots) in [("host-a", frameToken, [repo]), ("host-b", otherToken, [other])] {
            let session: [String: Any] = ["token": token, "groupID": group, "allowedRepoRoots": roots.map(\.path)]
            try JSONSerialization.data(withJSONObject: session)
                .write(to: trustedRoot.appendingPathComponent(".branch-session-\(group).json"))
        }
        // A malformed and an oversized-looking file contribute nothing.
        try Data("{".utf8).write(to: trustedRoot.appendingPathComponent(".branch-session-broken.json"))
        try Data("{}".utf8).write(to: trustedRoot.appendingPathComponent(".branch-session-bad group.json"))

        let roots = DiffViewerHostActions.allowedRepoRoots(forToken: frameToken, trustedRoot: trustedRoot)
        #expect(roots.map { $0.standardizedFileURL.path } == [repo.standardizedFileURL.path])
        #expect(DiffViewerHostActions.allowedRepoRoots(forToken: "0000000000000000", trustedRoot: trustedRoot).isEmpty)
        #expect(DiffViewerHostActions.allowedRepoRoots(forToken: "short", trustedRoot: trustedRoot).isEmpty)

        let resolved = try DiffViewerHostActions.resolveFileURL(path: "src/main.swift", allowedRepoRoots: roots)
        #expect(resolved.resolvingSymlinksInPath().path == repo.appendingPathComponent("src/main.swift").resolvingSymlinksInPath().path)
        func failure(_ path: String, roots: [URL]) -> DiffViewerHostActions.Failure? {
            do {
                _ = try DiffViewerHostActions.resolveFileURL(path: path, allowedRepoRoots: roots)
                return nil
            } catch let failure as DiffViewerHostActions.Failure {
                return failure
            } catch {
                return nil
            }
        }
        for traversal in ["../outside/secret.txt", "/etc/passwd", "src/../../outside/secret.txt", "src/./main.swift", "src//main.swift", "src/", "", "nul\0byte"] {
            #expect(failure(traversal, roots: roots) == .invalidPath, "\(traversal.debugDescription)")
        }
        // Inside the allow-listed repository but absent.
        #expect(failure("src/missing.swift", roots: roots) == .fileNotFound)
        // A directory is not a file to open.
        #expect(failure("src", roots: roots) == .fileNotFound)
        // Through the symlink the file exists, outside the repository.
        #expect(failure("escape/secret.txt", roots: roots) == .notAllowed)
        // Another token's allow-list binds a different repository: the path
        // resolves under that repository, where no such file exists, and the
        // first token's file is never consulted.
        let otherRoots = DiffViewerHostActions.allowedRepoRoots(forToken: otherToken, trustedRoot: trustedRoot)
        #expect(otherRoots.map { $0.standardizedFileURL.path } == [other.standardizedFileURL.path])
        #expect(failure("src/main.swift", roots: otherRoots) == .fileNotFound)
        #expect(failure("src/main.swift", roots: []) == .notAllowed)
        #expect(DiffViewerHostActions.isValidRepoRelativePath("-dash.txt"))
        #expect(DiffViewerHostActions.isValidRepoRelativePath("weird name.txt"))
    }

    /// End to end through the bridge's handler: an admitted request opens
    /// exactly one surface in the associated workspace through the injected
    /// opener; anything the gate refuses opens nothing.
    @Test(.timeLimit(.minutes(1)))
    func hostOpenFileOpensExactlyOneSurfaceThroughTheInjectedOpener() async throws {
        let previousApp = AppDelegate.shared
        let app = AppDelegate()
        defer { AppDelegate.shared = previousApp }
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { manager.finalizeAllWorkspacesForWindowClose() }
        app.tabManager = manager
        let workspace = try #require(manager.selectedWorkspace)
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        DiffCommentsBridge.associateHostOwned(workspaceId: workspace.id, with: webView)

        // The allow-list lives where the sidecar and CLI keep theirs.
        let token = UUID().uuidString.lowercased()
        let group = "host-open-\(UUID().uuidString.lowercased())"
        let trustedRoot = CmuxDiffViewerSessionPreparer.defaultTrustedRootURL
        try FileManager.default.createDirectory(at: trustedRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-host-open-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try "# Notes".write(to: repo.appendingPathComponent("docs/notes.md"), atomically: true, encoding: .utf8)
        let sessionURL = trustedRoot.appendingPathComponent(".branch-session-\(group).json")
        try JSONSerialization.data(withJSONObject: ["token": token, "groupID": group, "allowedRepoRoots": [repo.path]])
            .write(to: sessionURL)
        defer {
            try? FileManager.default.removeItem(at: sessionURL)
            try? FileManager.default.removeItem(at: repo)
        }

        var opened: [(UUID, String)] = []
        let opener: @MainActor (Workspace, String) -> Bool = { workspace, path in
            opened.append((workspace.id, path))
            return true
        }
        func request(_ path: String, token requestToken: String = token) -> [String: Any] {
            ["id": "open-\(path)", "version": 1, "method": "hostOpenFile", "params": ["capabilityToken": requestToken, "path": path]]
        }
        func code(of response: [String: Any]) -> String? {
            (response["error"] as? [String: Any])?["code"] as? String
        }

        let response = await DiffViewerHostActions.handle(body: request("docs/notes.md"), webView: webView, open: opener)
        #expect((response["result"] as? [String: Any])?["type"] as? String == "fileOpened")
        #expect(response["id"] as? String == "open-docs/notes.md")
        #expect(opened.count == 1)
        #expect(opened.first?.0 == workspace.id)
        #expect(opened.first.map { URL(fileURLWithPath: $0.1).resolvingSymlinksInPath().path }
            == repo.appendingPathComponent("docs/notes.md").resolvingSymlinksInPath().path)

        // An unknown token binds no repository; a traversal never resolves; a
        // path outside the allow-listed repository is refused; a missing file
        // is reported; none of them open anything.
        let unknown = await DiffViewerHostActions.handle(body: request("docs/notes.md", token: UUID().uuidString.lowercased()), webView: webView, open: opener)
        #expect(code(of: unknown) == "notAllowed")
        let traversal = await DiffViewerHostActions.handle(body: request("../notes.md"), webView: webView, open: opener)
        #expect(code(of: traversal) == "invalidPath")
        let outside = await DiffViewerHostActions.handle(body: request("docs/missing.md"), webView: webView, open: opener)
        #expect(code(of: outside) == "fileNotFound")
        let malformed = await DiffViewerHostActions.handle(body: ["id": "x", "version": 1, "method": "hostOpenFile", "params": ["capabilityToken": token]], webView: webView, open: opener)
        #expect(code(of: malformed) == "invalidPath")
        // A web view without a live workspace cannot open anything either.
        let stray = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let unassociated = await DiffViewerHostActions.handle(body: request("docs/notes.md"), webView: stray, open: opener)
        #expect(code(of: unassociated) == "unresolvedWorkspace")
        #expect(opened.count == 1)
        // A refusal from the workspace surfaces as its own code.
        let declined = await DiffViewerHostActions.handle(body: request("docs/notes.md"), webView: webView) { _, _ in false }
        #expect(code(of: declined) == "openFailed")
    }

    @Test
    func policyBindsTheCapabilityTokenToTheFrame() {
        let otherToken = "fedcba9876543210"
        #expect(rejection(body("sessionOpen", token: otherToken), frameToken: frameToken, panelAssociated: true) == .tokenMismatch)
        #expect(rejection(body("sessionOpen", token: nil), frameToken: frameToken, panelAssociated: true) == .tokenMismatch)
        #expect(rejection(body("sessionOpen"), frameToken: nil, panelAssociated: true) == .tokenMismatch)
        #expect(rejection(
            body("worktreeCommit", token: otherToken, params: ["message": "x"]),
            frameToken: frameToken,
            panelAssociated: true
        ) == .tokenMismatch)
    }

    /// The per-path methods take the same gate as every other write: the
    /// frame's token and a live workspace association. The policy forwards
    /// the `paths` list as posted; the sidecar validates each entry against
    /// the session's repository, so an unmapped repository or a path outside
    /// it is refused there, never admitted here on its own.
    @Test
    func pathListWriteMethodsAreGatedLikeEveryWrite() {
        let otherToken = "fedcba9876543210"
        for method in ["worktreeStageFiles", "worktreeUnstageFiles", "worktreeDiscardFiles"] {
            let params: [String: Any] = [
                "sessionId": "01234567-89ab-cdef-0123-456789abcdef",
                "source": ["kind": "unstaged", "repoRoot": "/tmp/repo"],
                "paths": ["story.txt", "src/a.txt"],
            ]
            #expect(rejection(body(method, params: params), frameToken: frameToken, panelAssociated: true) == nil, "\(method)")
            #expect(rejection(body(method, params: params), frameToken: frameToken, panelAssociated: false) == .unassociatedPanel, "\(method)")
            #expect(rejection(body(method, token: otherToken, params: params), frameToken: frameToken, panelAssociated: true) == .tokenMismatch, "\(method)")
            #expect(rejection(body(method, token: nil, params: params), frameToken: frameToken, panelAssociated: true) == .tokenMismatch, "\(method)")
            #expect(rejection(body(method, params: params), frameToken: nil, panelAssociated: true) == .tokenMismatch, "\(method)")
            // A near-miss name is not a known method.
            #expect(rejection(body(method.lowercased(), params: params), frameToken: frameToken, panelAssociated: true) == .unknownMethod, "\(method)")
        }
    }

    @Test
    func writeMethodsAdditionallyRequireAnAssociatedWebView() {
        for method in DiffSidecarRequestPolicy.writeMethods.sorted() {
            #expect(
                rejection(body(method, params: ["path": "story.txt"]), frameToken: frameToken, panelAssociated: false)
                    == .unassociatedPanel,
                "\(method) needs an associated web view"
            )
            #expect(
                rejection(body(method, params: ["path": "story.txt"]), frameToken: frameToken, panelAssociated: true) == nil,
                "\(method) is forwarded from an associated web view"
            )
        }
    }

    @Test
    func onlyWriteMethodsConsultTheWebViewAssociation() {
        var lookups = 0
        func countingRejection(_ body: [String: Any], frameToken: String?) -> DiffSidecarRequestPolicy.Rejection? {
            DiffSidecarRequestPolicy.rejection(for: body, frameToken: frameToken) {
                lookups += 1
                return true
            }
        }
        // Reads, including ones the policy rejects for other reasons, never
        // pay for the window/workspace walk.
        #expect(countingRejection(body("protocolHandshake", token: nil), frameToken: frameToken) == nil)
        for method in DiffSidecarRequestPolicy.readMethods.subtracting(["protocolHandshake"]).sorted() {
            #expect(countingRejection(body(method), frameToken: frameToken) == nil)
        }
        #expect(countingRejection(body("sessionOpen", token: "fedcba9876543210"), frameToken: frameToken) == .tokenMismatch)
        #expect(countingRejection(body("surface.respawn"), frameToken: frameToken) == .unknownMethod)
        #expect(lookups == 0)

        // A write with a mismatched token is refused before the lookup too.
        #expect(countingRejection(body("worktreeStageFiles", token: nil, params: ["paths": ["a"]]), frameToken: frameToken) == .tokenMismatch)
        #expect(lookups == 0)

        #expect(countingRejection(body("worktreeStageFiles", params: ["paths": ["a"]]), frameToken: frameToken) == nil)
        #expect(lookups == 1)
    }

    @Test
    func unregisteredWebViewsAreNotPanelAssociated() {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        #expect(!DiffCommentsBridge.isPanelAssociatedWebView(webView))
        #expect(!DiffCommentsBridge.isPanelAssociatedWebView(nil))
    }

    /// The docked Changes panel hosts its diff viewer outside any browser
    /// panel; associating the web view with the workspace it shows is what
    /// lets its write actions through and resolves the workspace for comments.
    @Test
    func hostOwnedWebViewsResolveTheirWorkspaceAndPassTheWriteGate() throws {
        let previousApp = AppDelegate.shared
        let app = AppDelegate()
        defer { AppDelegate.shared = previousApp }
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { manager.finalizeAllWorkspacesForWindowClose() }
        app.tabManager = manager
        let workspace = try #require(manager.selectedWorkspace)

        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        #expect(!DiffCommentsBridge.isPanelAssociatedWebView(webView))

        let stage = body("worktreeStageFiles", params: ["paths": ["story.txt"]])
        let isAssociated: () -> Bool = { DiffCommentsBridge.isPanelAssociatedWebView(webView) }

        DiffCommentsBridge.associateHostOwned(workspaceId: workspace.id, with: webView)
        #expect(DiffCommentsBridge.isPanelAssociatedWebView(webView))
        #expect(DiffSidecarRequestPolicy.rejection(for: stage, frameToken: frameToken, panelAssociated: isAssociated) == nil)

        // A workspace the app no longer knows about closes the gate again.
        DiffCommentsBridge.associateHostOwned(workspaceId: UUID(), with: webView)
        #expect(!DiffCommentsBridge.isPanelAssociatedWebView(webView))
        #expect(
            DiffSidecarRequestPolicy.rejection(for: stage, frameToken: frameToken, panelAssociated: isAssociated)
                == .unassociatedPanel
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func sessionPatchMissRefreshesTheManifestOnce() async throws {
        let token = UUID().uuidString.lowercased()
        let rootURL = CmuxDiffViewerSessionPreparer.defaultTrustedRootURL
        let fixtureURL = rootURL.appendingPathComponent("cmux-write-actions-\(UUID().uuidString)", isDirectory: true)
        let entryURL = fixtureURL.appendingPathComponent("index.html", isDirectory: false)
        let sessionID = UUID().uuidString.lowercased()
        let patchURL = fixtureURL.appendingPathComponent("diff-session-\(sessionID).patch", isDirectory: false)
        let otherPatchURL = fixtureURL.appendingPathComponent("other.patch", isDirectory: false)
        let manifestURL = rootURL.appendingPathComponent(".manifest-\(token).json", isDirectory: false)
        let leaseURL = rootURL.appendingPathComponent(".session-lease-\(token).lock", isDirectory: false)
        try FileManager.default.createDirectory(at: fixtureURL, withIntermediateDirectories: true)
        try "<!doctype html>".write(to: entryURL, atomically: true, encoding: .utf8)
        try "diff --git a/a b/a\n".write(to: patchURL, atomically: true, encoding: .utf8)
        try "diff --git a/b b/b\n".write(to: otherPatchURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: leaseURL)
            try? FileManager.default.removeItem(at: manifestURL)
            try? FileManager.default.removeItem(at: fixtureURL)
        }

        let handler = CmuxDiffViewerURLSchemeHandler()
        try await handler.register(
            token: token,
            files: [.init(requestPath: "/index.html", fileURL: entryURL, mimeType: "text/html")]
        )
        // The sidecar appends the session patch (and, here, an unrelated patch)
        // to the on-disk manifest after the in-memory session was installed.
        let manifest: [String: Any] = [
            "token": token,
            "files": [
                ["request_path": "/index.html", "file_path": entryURL.path, "mime_type": "text/html"],
                ["request_path": "/diff-session-\(sessionID).patch", "file_path": patchURL.path, "mime_type": "text/x-diff"],
                ["request_path": "/other.patch", "file_path": otherPatchURL.path, "mime_type": "text/x-diff"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL, options: .atomic)

        let sessionPatchRequest = try #require(URL(string: "cmux-diff-viewer://\(token)/diff-session-\(sessionID).patch"))
        let otherPatchRequest = try #require(URL(string: "cmux-diff-viewer://\(token)/other.patch"))
        #expect(handler.registeredFile(for: sessionPatchRequest) == nil)
        // Ordinary misses stay cache-only; only typed session patches refresh.
        #expect(await handler.registeredFileRefreshingSessionPatch(for: otherPatchRequest, token: token) == nil)
        let served = await handler.registeredFileRefreshingSessionPatch(for: sessionPatchRequest, token: token)
        #expect(served?.mimeType == "text/x-diff")
        #expect(served?.fileURL.standardizedFileURL.resolvingSymlinksInPath() == patchURL.standardizedFileURL.resolvingSymlinksInPath())
        // The refreshed session now serves every manifest entry from the cache.
        #expect(handler.registeredFile(for: otherPatchRequest) != nil)
    }
}
