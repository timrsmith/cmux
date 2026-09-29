import AppKit
import CmuxBrowser
import SwiftUI
import WebKit

/// Right sidebar "Changes" mode: the git diff viewer for the selected
/// workspace's uncommitted changes, docked like Files/Find/Dock. The document
/// itself is the same `cmux diff --unstaged` page Cmd+Shift+D opens in a pane;
/// this view only hosts it and shows placeholders for the non-ready states.
struct RightSidebarChangesPanelView: View {
    @ObservedObject var store: RightSidebarChangesStore

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("RightSidebarChangesPanel")
    }

    @ViewBuilder
    private var content: some View {
        // One `if` keeps the web view's identity stable across loading/ready
        // transitions, so a new repository swaps the URL in place instead of
        // tearing the WKWebView down and recreating it.
        if let url = store.state.displayedURL {
            ZStack {
                RightSidebarChangesWebView(
                    url: url,
                    reloadGeneration: store.reloadGeneration,
                    workspaceId: store.target?.workspaceId
                )
                if case .loading = store.state {
                    loadingIndicator
                }
            }
        } else {
            switch store.state {
            case .noWorkspace:
                placeholder(
                    symbolName: "plusminus.circle",
                    title: String(
                        localized: "rightSidebar.changes.empty.noWorkspace",
                        defaultValue: "No workspace selected"
                    ),
                    detail: String(
                        localized: "rightSidebar.changes.empty.noWorkspaceHint",
                        defaultValue: "Select a workspace to see its uncommitted changes."
                    )
                )
            case .notARepository(let path):
                placeholder(
                    symbolName: "folder.badge.questionmark",
                    title: String(
                        localized: "rightSidebar.changes.empty.notARepository",
                        defaultValue: "Not a Git repository"
                    ),
                    detail: (path as NSString).abbreviatingWithTildeInPath
                )
            case .loading, .ready:
                loadingIndicator
            case .failed(let message):
                // `message` is always one of the store's localized failure
                // texts; the CLI's own output never reaches the panel.
                placeholder(
                    symbolName: "exclamationmark.triangle",
                    title: String(
                        localized: "rightSidebar.changes.failed",
                        defaultValue: "Couldn't load changes"
                    ),
                    detail: message
                )
            }
        }
    }

    private var loadingIndicator: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(String(
                localized: "rightSidebar.changes.loading",
                defaultValue: "Loading changes…"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private func placeholder(symbolName: String, title: String, detail: String?) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbolName)
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .truncationMode(.middle)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Navigation policy

/// What the docked diff viewer's web view may navigate to. The document is
/// app-generated but renders untrusted repository content, and the sidebar
/// has no address bar or back button, so the web view only ever shows the
/// registered files of the page it was given. Everything else is cancelled;
/// web links the user activates open in the system browser instead.
enum RightSidebarChangesNavigationPolicy {
    enum Decision: Equatable {
        case allow
        case cancel
        /// Cancel in the web view and hand the URL to the default browser.
        case openExternally
    }

    /// The branch base picker regenerates the diff through this token-scoped
    /// route (`?group=…&repo=…&base=…`), which the scheme handler validates
    /// before it answers with a redirect stub back to a registered page.
    static let branchRoutePath = "/__cmux_diff_viewer_branch"

    /// - Parameters:
    ///   - token: The capability token of the page the panel currently hosts.
    ///   - isRegistered: `CmuxDiffViewerURLSchemeHandler.allowsNavigation(to:)`
    ///     for the live handler; injected so the rule is testable.
    static func decision(
        for url: URL?,
        navigationType: WKNavigationType,
        isMainFrame: Bool,
        token: String?,
        isRegistered: (URL) -> Bool
    ) -> Decision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
        switch scheme {
        case "about":
            // WebKit's blank document and `srcdoc` frames carry no remote content.
            return .allow
        case CmuxDiffViewerURLSchemeHandler.scheme:
            guard let token, url.host == token else { return .cancel }
            if isRegistered(url) { return .allow }
            if isMainFrame, url.path == branchRoutePath, url.query != nil {
                return .allow
            }
            return .cancel
        case "http", "https":
            // Only a user-activated top-level link leaves the app; scripted
            // redirects and framed content stay cancelled.
            return isMainFrame && navigationType == .linkActivated ? .openExternally : .cancel
        default:
            return .cancel
        }
    }

    /// Popup requests (`window.open`, `target="_blank"`): the sidebar never
    /// hosts a second web view, so web URLs go to the system browser and
    /// nothing else opens anywhere.
    static func popupDecision(for url: URL?) -> Decision {
        guard let scheme = url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .cancel
        }
        return .openExternally
    }
}

/// Applies ``RightSidebarChangesNavigationPolicy`` to the panel's web view and
/// forwards navigation lifecycle to `CmuxWebView`'s diff viewer document state
/// the way `BrowserPanel` does, so reloads and URL swaps reset it.
@MainActor
final class RightSidebarChangesNavigationDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// Token of the page the panel currently hosts; navigations for any
    /// other token are cancelled.
    var token: String?
    /// Same system-browser handoff as the browser pane's external opener.
    var openExternally: (URL) -> Void = { _ = NSWorkspace.shared.open($0) }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let decisionHandler = BrowserNavigationActionDecisionHandler(
            decisionHandler,
            fallbackPolicy: .cancel,
            label: "RightSidebarChangesNavigationDelegate.navigationAction"
        ).closure
        let url = navigationAction.request.url
        let decision = RightSidebarChangesNavigationPolicy.decision(
            for: url,
            navigationType: navigationAction.navigationType,
            isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
            token: token,
            isRegistered: { CmuxDiffViewerURLSchemeHandler.shared.allowsNavigation(to: $0) }
        )
        switch decision {
        case .allow:
            decisionHandler(.allow)
        case .openExternally:
            if let url { openExternally(url) }
            decisionHandler(.cancel)
        case .cancel:
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let url = navigationAction.request.url
        if RightSidebarChangesNavigationPolicy.popupDecision(for: url) == .openExternally, let url {
            openExternally(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        (webView as? CmuxWebView)?.diffViewerNavigationDidStart(navigation)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        (webView as? CmuxWebView)?.diffViewerNavigationDidCommit(navigation)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        (webView as? CmuxWebView)?.diffViewerNavigationDidCancel(navigation)
    }
}

// MARK: - Web view

/// Hosts one `CmuxWebView` configured exactly like a browser pane (custom
/// diff-viewer scheme handler plus the review-comment bridges), so the docked
/// document behaves like the pane version. The view is reused across reloads
/// and URL swaps to avoid remounting (and flashing) the web content.
///
/// The web view is associated with the workspace it shows as a host-owned
/// diff viewer, which is what lets the sidecar bridge accept its write actions
/// and the comments bridge register pending submissions for that workspace.
struct RightSidebarChangesWebView: NSViewRepresentable {
    let url: URL
    let reloadGeneration: UInt64
    let workspaceId: UUID?

    @MainActor
    final class Coordinator {
        var loadedURL: URL?
        var reloadGeneration: UInt64 = 0
        var associatedWorkspaceId: UUID?
        /// WebKit holds its delegates weakly; the coordinator owns this one.
        let navigationDelegate = RightSidebarChangesNavigationDelegate()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> CmuxWebView {
        let configuration = WKWebViewConfiguration()
        BrowserPanel.configureWebViewConfiguration(
            configuration,
            websiteDataStore: .default()
        )
        let webView = CmuxWebView(frame: .zero, configuration: configuration, host: CmuxWebViewAppHost())
        webView.allowsBackForwardNavigationGestures = false
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        webView.navigationDelegate = context.coordinator.navigationDelegate
        webView.uiDelegate = context.coordinator.navigationDelegate
        // The diff viewer draws its own themed background; match the browser
        // pane's transparent-internal-page treatment so the sidebar chrome shows
        // through while the document loads.
        webView.wantsLayer = true
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = GhosttyBackgroundTheme.currentColor()
        webView.setAccessibilityIdentifier("RightSidebarChangesWebView")
        context.coordinator.reloadGeneration = reloadGeneration
        associateWorkspace(with: webView, coordinator: context.coordinator)
        load(url, in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: CmuxWebView, context: Context) {
        associateWorkspace(with: webView, coordinator: context.coordinator)
        if context.coordinator.loadedURL != url {
            load(url, in: webView, coordinator: context.coordinator)
            context.coordinator.reloadGeneration = reloadGeneration
            return
        }
        if context.coordinator.reloadGeneration != reloadGeneration {
            context.coordinator.reloadGeneration = reloadGeneration
            Self.refresh(webView)
        }
    }

    /// The page exposes `window.cmuxDiffViewer.refresh()` for working-tree
    /// views: it reopens the diff session in place, keeping scroll position,
    /// per-file collapse state, and the repository status already shown. A
    /// page without it (still loading, a static snapshot, an older bundle)
    /// reloads the document instead.
    static let inPlaceRefreshScript = """
    (function () {
      var viewer = window.cmuxDiffViewer;
      return !!(viewer && typeof viewer.refresh === "function" && viewer.refresh());
    })()
    """

    private static func refresh(_ webView: CmuxWebView) {
        webView.evaluateJavaScript(inPlaceRefreshScript) { result, _ in
            if (result as? Bool) != true {
                webView.reload()
            }
        }
    }

    private func associateWorkspace(with webView: CmuxWebView, coordinator: Coordinator) {
        guard let workspaceId, coordinator.associatedWorkspaceId != workspaceId else { return }
        coordinator.associatedWorkspaceId = workspaceId
        DiffCommentsBridge.associateHostOwned(workspaceId: workspaceId, with: webView)
    }

    private func load(_ url: URL, in webView: CmuxWebView, coordinator: Coordinator) {
        coordinator.loadedURL = url
        // The page's token is its URL host; the delegate scopes every
        // navigation to it until the store hands over another page.
        coordinator.navigationDelegate.token = url.host
        webView.markTrustedInternalNavigation(url)
        webView.load(URLRequest(url: url))
    }
}
