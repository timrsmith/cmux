import Foundation
import WebKit

/// Admission policy for `cmuxDiff` bridge requests before they reach the Rust
/// sidecar (or, for `hostMethods`, the native host action). Deny is the
/// default: only the protocol's known methods are forwarded, every method that
/// names a capability token must name the token of the frame it was posted
/// from, and working-tree mutations and host actions additionally require the
/// web view to be associated with a live workspace (a browser panel or the
/// app's own docked Changes viewer). The sidecar re-authorizes the token,
/// repository, and session on its side; `DiffViewerHostActions` re-validates
/// the path and repository for host actions.
enum DiffSidecarRequestPolicy {
    /// Read-only protocol methods the viewer page may forward. The repository
    /// status query runs Git and the forge CLI but changes nothing, so it needs
    /// the frame's token and no workspace association.
    static let readMethods: Set<String> = [
        "protocolHandshake",
        "sessionOpen",
        "sessionClose",
        "branchList",
        "branchChange",
        "worktreeRepositoryStatus",
    ]

    /// Methods that change the repository's index or working tree, or act on
    /// its remote (push, pull request creation). The `...Files` methods are
    /// the selection (batch) forms of the single-file writes and are gated
    /// identically; the sidecar validates each path they name.
    static let writeMethods: Set<String> = [
        "worktreeRevertFile",
        "worktreeStageFile",
        "worktreeUnstageFile",
        "worktreeStageFiles",
        "worktreeUnstageFiles",
        "worktreeDiscardFiles",
        "worktreeRevertHunk",
        "worktreeCommit",
        "worktreeDiscardAll",
        "worktreeStageAll",
        "worktreeUnstageAll",
        "worktreePush",
        "worktreeCreatePullRequest",
    ]

    /// Methods the native host answers itself (`DiffViewerHostActions`). They
    /// open content in the hosting workspace, so they are gated like writes.
    static let hostMethods: Set<String> = DiffViewerHostActions.methods

    enum Rejection: Equatable {
        /// The method is not part of the forwarded protocol surface.
        case unknownMethod
        /// `params.capabilityToken` is missing or differs from the frame's token.
        case tokenMismatch
        /// A write or host method arrived from a web view no browser panel registered.
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
        let isWrite = writeMethods.contains(method) || hostMethods.contains(method)
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
