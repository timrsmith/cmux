import CmuxSettings
import CmuxSettingsUI
import CmuxWorkspaces
import Foundation

/// Row titles for the Files header's Editor submenu, one per
/// `FileExplorerDoubleClickAction`. The Terminal Editor row names what it
/// would run, so the choice is visible before the user picks it: the first
/// word of a configured `fileEditor.terminalEditorCommand`, or the shell
/// resolution (`$VISUAL`, `$EDITOR` or `vi`) when none is configured.
enum FilesPanelEditorMenuItems {
    /// The submenu row title for `action` given the current
    /// `fileEditor.terminalEditorCommand` value.
    static func title(for action: FileExplorerDoubleClickAction, configuredCommand: String) -> String {
        let title = action.localizedTitle
        guard action == .terminalEditor else { return title }
        guard let command = TerminalEditorCommandResolver(configuredCommand: configuredCommand).explicitCommand else {
            return String(
                localized: "filesPanel.header.editor.terminalEditorShellFallback",
                defaultValue: "\(title) ($VISUAL, $EDITOR or vi)"
            )
        }
        let executable = PreferredEditorService.shellWords(command).first ?? command
        let editorName = (executable as NSString).lastPathComponent
        return String(
            localized: "filesPanel.header.editor.terminalEditorWithCommand",
            defaultValue: "\(title) (\(editorName))"
        )
    }
}
