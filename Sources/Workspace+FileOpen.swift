import Bonsplit

/// The routing every sidebar-style file open shares: the file tree click, the
/// right sidebar's file preview, and the diff viewer's `hostOpenFile` action
/// all land in the focused pane (or the first), reusing an existing preview of
/// the file and duplicating it only when that preview is the focused tab.
extension Workspace {
    /// The pane such an open targets: the focused pane, or the first when
    /// nothing is focused; `nil` in a workspace without panes.
    var fileOpenTargetPane: PaneID? {
        bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first
    }

    /// Opens `path` in `pane` with focus, reusing an existing preview.
    /// Returns whether a surface was opened or focused.
    @discardableResult
    func openFile(_ path: String, inPane pane: PaneID) -> Bool {
        !openFileSurfaces(
            inPane: pane,
            filePaths: [path],
            focus: true,
            reuseExisting: true,
            duplicateWhenFocused: true
        ).isEmpty
    }

    /// ``openFile(_:inPane:)`` in ``fileOpenTargetPane``; `false` when the
    /// workspace has no pane to open into.
    @discardableResult
    func openFileInFocusedPane(_ path: String) -> Bool {
        guard let pane = fileOpenTargetPane else { return false }
        return openFile(path, inPane: pane)
    }
}
