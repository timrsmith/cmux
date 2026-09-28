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
        for method in ["sessionOpen", "sessionClose", "branchList", "branchChange"] {
            #expect(
                rejection(body(method), frameToken: frameToken, panelAssociated: false) == nil,
                "\(method) is a read method"
            )
        }
        for method in ["surface.respawn", "worktreeRunCommand", "", "sessionopen"] {
            #expect(
                rejection(body(method), frameToken: frameToken, panelAssociated: true) == .unknownMethod,
                "\(method) is not forwarded"
            )
        }
        #expect(rejection(["id": "request", "version": 1], frameToken: frameToken, panelAssociated: true) == .unknownMethod)
        #expect(DiffSidecarRequestPolicy.readMethods.isDisjoint(with: DiffSidecarRequestPolicy.writeMethods))
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
        #expect(countingRejection(body("worktreeStageFile", token: nil, params: ["path": "a"]), frameToken: frameToken) == .tokenMismatch)
        #expect(lookups == 0)

        #expect(countingRejection(body("worktreeStageFile", params: ["path": "a"]), frameToken: frameToken) == nil)
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

        let stage = body("worktreeStageFile", params: ["path": "story.txt"])
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
