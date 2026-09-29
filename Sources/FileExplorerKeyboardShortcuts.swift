import AppKit
import CmuxSettings
import CmuxWorkspaces

/// Opens a local file activated in the file explorer.
///
/// The editor choice (`fileExplorer.doubleClickAction`) is resolved in one
/// place, `Workspace.openFile(_:inPane:activation:)`, which every
/// `onOpenFilePreview` host reaches through `FileExplorerPreviewCoordinator`;
/// this entry point stays so the tree's two activation sites (outline row and
/// search result) share it. Remote providers never get here: their hosts
/// call the callback directly and the coordinator shows a downloaded copy.
@MainActor
func performFileExplorerFileOpen(path: String, onOpenFilePreview: (String) -> Void) {
    onOpenFilePreview(path)
}

@MainActor
extension FileExplorerPanelView.Coordinator {
    func openSelectedNode(in outlineView: NSOutlineView) {
        guard let row = resolvedSelectionRow(in: outlineView) else { return }
        openNode(in: outlineView, at: row)
    }

    func openNode(in outlineView: NSOutlineView, at row: Int) {
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? FileExplorerNode,
              node.resourceContextID == nil || node.resourceContextID == store.resourceContextID else { return }
        // A ghost file is deleted; there is nothing on disk to open. A ghost
        // directory still toggles like any folder so its deleted children show.
        guard !node.isGhost || node.isDirectory else { return }

        if node.isDirectory {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else if outlineView.isExpandable(node) {
                outlineView.expandItem(node)
            }
            return
        }

        guard store.provider is LocalFileExplorerProvider else {
            onOpenFilePreview(node.path)
            return
        }
        performFileExplorerFileOpen(path: node.path, onOpenFilePreview: onOpenFilePreview)
    }
}

extension FileExplorerNSOutlineView {
    func handleOpenSelectionShortcut(_ event: NSEvent) -> Bool {
        guard event.isFileExplorerOpenSelectionShortcut(in: fileExplorerPanelPlacement) else { return false }
        endQuickSearch()
        fileExplorerCoordinator?.openSelectedNode(in: self)
        return true
    }
}

extension FileExplorerSearchResultsTableView {
    func handleOpenSelectionShortcut(_ event: NSEvent) -> Bool {
        guard event.isFileExplorerOpenSelectionShortcut(in: fileExplorerPanelPlacement) else { return false }
        onCommit?()
        return true
    }
}

extension FileExplorerSearchField {
    func handleOpenSelectionShortcut(_ event: NSEvent) -> Bool {
        if (currentEditor() as? NSTextView)?.hasMarkedText() == true { return false }
        guard !RightSidebarKeyboardNavigation.isPlainPrintableText(event) else { return false }
        guard event.isFileExplorerOpenSelectionShortcut(in: fileExplorerPanelPlacement) else { return false }
        onCommit?()
        return true
    }
}

@MainActor
extension NSEvent {
    func isFileExplorerOpenSelectionShortcut(in placement: FileExplorerPanelPlacement) -> Bool {
        guard type == .keyDown else { return false }
        return isFileExplorerOpenSelectionShortcut(in: placement.openSelectionShortcutContext(for: self))
    }

    func isFileExplorerOpenSelectionShortcut(in context: ShortcutContext) -> Bool {
        KeyboardShortcutSettings.Action.fileExplorerOpenSelectionActions.contains { action in
            KeyboardShortcutSettings.shortcut(for: action).matches(event: self) &&
                KeyboardShortcutSettings.effectiveWhenClause(for: action).evaluate(context)
        }
    }
}

@MainActor
private extension FileExplorerPanelPlacement {
    func openSelectionShortcutContext(for event: NSEvent) -> ShortcutContext {
        var context = AppDelegate.shared?.shortcutEventFocusContext(event).shortcutContext ??
            ShortcutFocusState(browser: false, markdown: false, sidebar: false).context
        switch self {
        case .rightSidebar, .pane:
            context.setBool(ShortcutFocusAtom.sidebarFocus.rawValue, true)
            context.setBool(ShortcutFocusAtom.browserFocus.rawValue, false)
            context.setBool(ShortcutFocusAtom.markdownFocus.rawValue, false)
            context.setBool(ShortcutFocusAtom.terminalFocus.rawValue, false)
        }
        return context
    }
}

private extension KeyboardShortcutSettings.Action {
    static var fileExplorerOpenSelectionActions: [Self] {
        [.fileExplorerOpenSelection, .fileExplorerOpenSelectionFinderAlias]
    }
}
