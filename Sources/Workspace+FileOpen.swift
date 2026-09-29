import Bonsplit
import CmuxSettings
import CmuxWorkspaces
import Foundation

/// The routing every sidebar-style file open shares: the file tree click, the
/// right sidebar's file preview, and the diff viewer's `hostOpenFile` action
/// all resolve the user's editor choice (`fileExplorer.doubleClickAction`)
/// here. The native editor lands in the focused pane (or the first), reusing
/// an existing preview of the file and duplicating it only when that preview
/// is the focused tab; the terminal editor opens a new terminal surface in
/// that same pane; the two external choices leave cmux.
extension Workspace {
    /// The pane such an open targets: the focused pane, or the first when
    /// nothing is focused; `nil` in a workspace without panes.
    var fileOpenTargetPane: PaneID? {
        bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first
    }

    /// Opens `path` with focus according to `activation`, which defaults to
    /// the stored choice. Pass `.preview` to force the native editor (a caller
    /// that shows a downloaded copy, for example). Returns whether something
    /// was opened or focused.
    @discardableResult
    func openFile(
        _ path: String,
        inPane pane: PaneID,
        activation: FileExplorerFileActivation? = nil
    ) -> Bool {
        switch activation ?? FileExplorerDoubleClickActionSettings.resolvedFileActivation() {
        case .preview:
            return !openFileSurfaces(
                inPane: pane,
                filePaths: [path],
                focus: true,
                reuseExisting: true,
                duplicateWhenFocused: true
            ).isEmpty
        case .terminalEditor:
            return openFileInTerminalEditor(path, inPane: pane)
        case .defaultEditor:
            return FileExternalOpenAction.openDefault(fileURL: URL(fileURLWithPath: path))
        case .preferredEditor:
            PreferredEditorService(defaults: .standard).open(URL(fileURLWithPath: path))
            return true
        }
    }

    /// ``openFile(_:inPane:activation:)`` in ``fileOpenTargetPane``; `false`
    /// when the workspace has no pane to open into.
    @discardableResult
    func openFileInFocusedPane(
        _ path: String,
        activation: FileExplorerFileActivation? = nil
    ) -> Bool {
        guard let pane = fileOpenTargetPane else { return false }
        return openFile(path, inPane: pane, activation: activation)
    }

    /// Opens `path` in a new, focused terminal surface in `pane` running the
    /// resolved terminal editor, started in the file's directory. The command
    /// runs through the user's login shell so profile-managed `PATH` entries
    /// (Homebrew's `nvim`, for example) resolve as they do in a normal tab.
    @discardableResult
    func openFileInTerminalEditor(_ path: String, inPane pane: PaneID) -> Bool {
        let request = TerminalEditorCommandResolver(defaults: .standard).openRequest(forFilePath: path)
        return newTerminalSurface(
            inPane: pane,
            focus: true,
            workingDirectory: request.workingDirectory,
            initialCommand: WorkspaceInitialCommandLoginShell.wrap(request.command)
        ) != nil
    }
}
