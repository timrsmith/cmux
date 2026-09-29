import AppKit

extension TabManager {
    /// Returns the focused panel if it is a main-area or Dock browser.
    var focusedBrowserPanel: BrowserPanel? {
        if let appDelegate = AppDelegate.shared,
           let windowId = appDelegate.windowId(for: self),
           let window = appDelegate.mainWindow(for: windowId) {
            return appDelegate.focusedBrowserPanelForAction(in: window)
        }
        return focusedWorkspaceBrowserPanel
    }

    /// Workspace-tree browser resolution used by the window-aware AppDelegate
    /// route without recursively consulting the per-window Dock.
    var focusedWorkspaceBrowserPanel: BrowserPanel? {
        guard let tab = selectedWorkspace else { return nil }
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if let window, let responder = window.firstResponder {
            if let addressBarPanelId = AppDelegate.shared?.focusedBrowserAddressBarPanelId(),
               browserOmnibarPanelId(for: responder) == addressBarPanelId,
               let browser = tab.browserPanel(for: addressBarPanelId) {
                return browser
            }
            if let context = BrowserWindowPortalRegistry.paneDropContext(owning: responder, in: window),
               context.workspaceId == tab.id,
               let browser = tab.browserPanel(for: context.panelId) {
                return browser
            }
        }
        if let panelId = tab.focusedPanelId,
           let browser = tab.panels[panelId] as? BrowserPanel {
            return browser
        }
        return nil
    }

    var focusedTextFilePreviewPanel: FilePreviewPanel? {
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId,
              let panel = tab.panels[panelId] as? FilePreviewPanel,
              panel.previewMode == .text else { return nil }
        return panel
    }

    /// Returns the focused panel if it's a MarkdownPanel showing the rendered
    /// preview, nil otherwise. Zoom applies to the preview WKWebView, so the raw
    /// text-edit mode is deliberately excluded.
    var focusedMarkdownPanel: MarkdownPanel? {
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId,
              let panel = tab.panels[panelId] as? MarkdownPanel,
              panel.displayMode == .preview else { return nil }
        return panel
    }

    /// The panel that answers the Edit > Find family, in the precedence the
    /// find shortcuts have always used: the selected terminal, then the
    /// focused browser (main area or Dock), then the focused file preview
    /// showing its text editor, then the focused markdown panel (which picks
    /// its preview or text editor itself from its display mode).
    var focusedFindablePanel: (any FindablePanel)? {
        if let terminalPanel = selectedTerminalPanel {
            return terminalPanel
        }
        if let browserPanel = focusedBrowserPanel {
            return browserPanel
        }
        if let filePreview = focusedTextFilePreviewPanel {
            return filePreview
        }
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId else { return nil }
        return tab.panels[panelId] as? MarkdownPanel
    }

    /// The focused panel when it edits text natively: a file preview showing
    /// its text editor, or a markdown panel in its text (source) mode. Used
    /// by the file-editor commands (`performFocusedTextEditorAction`); find
    /// routes through `focusedFindablePanel` instead.
    var focusedTextEditingPanel: (any FilePreviewTextEditingPanel)? {
        if let filePreview = focusedTextFilePreviewPanel {
            return filePreview
        }
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId,
              let markdown = tab.panels[panelId] as? MarkdownPanel,
              markdown.displayMode == .text else { return nil }
        return markdown
    }

    @discardableResult
    func zoomInFocusedTextFilePreview() -> Bool {
        performFocusedTextFilePreviewZoom { $0.zoomTextPreviewIn() } ?? false
    }

    @discardableResult
    func zoomOutFocusedTextFilePreview() -> Bool {
        performFocusedTextFilePreviewZoom { $0.zoomTextPreviewOut() } ?? false
    }

    @discardableResult
    func resetZoomFocusedTextFilePreview() -> Bool {
        performFocusedTextFilePreviewZoom { $0.resetTextPreviewZoom() } ?? false
    }

    @discardableResult
    func zoomInFocusedBrowserOrTextFilePreview() -> Bool {
        if let result = performFocusedTextFilePreviewZoom({ $0.zoomTextPreviewIn() }) { return result }
        return zoomInFocusedBrowser()
    }

    @discardableResult
    func zoomOutFocusedBrowserOrTextFilePreview() -> Bool {
        if let result = performFocusedTextFilePreviewZoom({ $0.zoomTextPreviewOut() }) { return result }
        return zoomOutFocusedBrowser()
    }

    @discardableResult
    func resetZoomFocusedBrowserOrTextFilePreview() -> Bool {
        if let result = performFocusedTextFilePreviewZoom({ $0.resetTextPreviewZoom() }) { return result }
        return resetZoomFocusedBrowser()
    }
}
