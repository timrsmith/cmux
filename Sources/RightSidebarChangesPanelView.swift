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

    final class Coordinator {
        var loadedURL: URL?
        var reloadGeneration: UInt64 = 0
        var associatedWorkspaceId: UUID?
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
            webView.reload()
        }
    }

    private func associateWorkspace(with webView: CmuxWebView, coordinator: Coordinator) {
        guard let workspaceId, coordinator.associatedWorkspaceId != workspaceId else { return }
        coordinator.associatedWorkspaceId = workspaceId
        DiffCommentsBridge.associateHostOwned(workspaceId: workspaceId, with: webView)
    }

    private func load(_ url: URL, in webView: CmuxWebView, coordinator: Coordinator) {
        coordinator.loadedURL = url
        webView.markTrustedInternalNavigation(url)
        webView.load(URLRequest(url: url))
    }
}
