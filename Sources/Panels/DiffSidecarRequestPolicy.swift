import Foundation
import WebKit

/// Admission policy for `cmuxDiff` bridge requests before they reach the Rust
/// sidecar. Deny is the default: only the protocol's known methods are
/// forwarded, every method that names a capability token must name the token
/// of the frame it was posted from, and working-tree mutations additionally
/// require the web view to be associated with a live workspace (a browser
/// panel or the app's own docked Changes viewer). The sidecar re-authorizes
/// the token, repository, and session on its side.
enum DiffSidecarRequestPolicy {
    /// Read-only protocol methods the viewer page may forward.
    static let readMethods: Set<String> = [
        "protocolHandshake",
        "sessionOpen",
        "sessionClose",
        "branchList",
        "branchChange",
    ]

    /// Methods that change the repository's index or working tree.
    static let writeMethods: Set<String> = [
        "worktreeRevertFile",
        "worktreeStageFile",
        "worktreeUnstageFile",
        "worktreeRevertHunk",
        "worktreeCommit",
    ]

    enum Rejection: Equatable {
        /// The method is not part of the forwarded protocol surface.
        case unknownMethod
        /// `params.capabilityToken` is missing or differs from the frame's token.
        case tokenMismatch
        /// A write method arrived from a web view no browser panel registered.
        case unassociatedPanel
    }

    /// Returns the validated request body, or `nil` when the message must be
    /// answered with `notAllowed` instead of reaching the sidecar.
    @MainActor
    static func acceptedBody(for message: WKScriptMessage) -> [String: Any]? {
        guard DiffSidecarBridge.isTrustedSidecarFrame(message.frameInfo),
              JSONSerialization.isValidJSONObject(message.body),
              let body = message.body as? [String: Any] else {
            return nil
        }
        let frameToken = DiffCommentsBridge.diffViewerToken(from: message.frameInfo.request.url)
        let accepted = rejection(for: body, frameToken: frameToken) {
            // Resolving the association walks windows and workspaces, so it
            // runs only for the write methods that need it.
            DiffCommentsBridge.isPanelAssociatedWebView(message.webView)
        } == nil
        return accepted ? body : nil
    }

    /// Pure decision: `frameToken` is the token parsed from the posting frame's
    /// URL and `panelAssociated` reports whether that web view resolves to a
    /// live workspace (through a browser panel or a host-owned association).
    /// It is consulted only for write methods.
    static func rejection(
        for body: [String: Any],
        frameToken: String?,
        panelAssociated: () -> Bool
    ) -> Rejection? {
        guard let method = body["method"] as? String else {
            return .unknownMethod
        }
        let isWrite = writeMethods.contains(method)
        guard isWrite || readMethods.contains(method) else {
            return .unknownMethod
        }
        if method != "protocolHandshake" {
            let params = body["params"] as? [String: Any]
            guard let requestToken = params?["capabilityToken"] as? String,
                  let frameToken,
                  requestToken == frameToken else {
                return .tokenMismatch
            }
        }
        if isWrite && !panelAssociated() {
            return .unassociatedPanel
        }
        return nil
    }
}
