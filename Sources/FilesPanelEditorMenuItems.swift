import CmuxSettings
import CmuxSettingsUI
import Foundation

/// One row of the Files header's Editor submenu.
struct FilesPanelEditorMenuItem: Equatable {
    let action: FileExplorerDoubleClickAction
    let title: String
}

/// The rows of the Files header's Editor submenu, in
/// `FileExplorerDoubleClickAction.allCases` order: Native Editor, Terminal
/// Editor, Default App, Preferred Editor App. The Terminal Editor row names
/// the editor it would run when no command is configured, so the fallback is
/// visible before the user picks it.
struct FilesPanelEditorMenuItems {
    let terminalEditor: TerminalEditorCommandResolver.Resolution

    var items: [FilesPanelEditorMenuItem] {
        FileExplorerDoubleClickAction.allCases.map { action in
            FilesPanelEditorMenuItem(action: action, title: title(for: action))
        }
    }

    private func title(for action: FileExplorerDoubleClickAction) -> String {
        let title = action.localizedTitle
        guard action == .terminalEditor, terminalEditor.source != .setting else { return title }
        let editorName = terminalEditor.displayName
        return String(
            localized: "filesPanel.header.editor.terminalEditorWithFallback",
            defaultValue: "\(title) (\(editorName))"
        )
    }
}
