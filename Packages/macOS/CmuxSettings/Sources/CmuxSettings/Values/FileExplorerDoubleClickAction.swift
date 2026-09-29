import Foundation

/// What activating a file in the file tree opens (`fileExplorer.doubleClickAction`).
///
/// Applies to a double-click in the tree, Return on a search result, and every
/// sidebar-style file open that shares the tree's routing (the right sidebar's
/// file preview, the diff viewer's Open in cmux). Directories are unaffected:
/// they always expand or collapse. The default, ``preview``, is the built-in
/// cmux editor, so existing users see no change. Declaration order is the
/// order the Settings picker and the Files header's Editor submenu list the
/// choices in.
public enum FileExplorerDoubleClickAction: String, CaseIterable, Sendable, SettingCodable {
    /// The built-in cmux file editor (the historical default).
    case preview
    /// A terminal surface in cmux running the user's terminal editor
    /// (`fileEditor.terminalEditorCommand`, else `$VISUAL`, `$EDITOR`, `vi`).
    case terminalEditor
    /// The macOS default application for the file type, identical to the
    /// file tree context menu's "Open in <App>" action.
    case defaultEditor
    /// The `app.preferredEditor` command, matching the terminal Cmd-click
    /// path. Falls back to ``defaultEditor`` when no command is configured.
    case preferredEditor
}
