import CmuxSettings
import CmuxSettingsUI
import SwiftUI

/// The "…" menu on the Files header, wherever the tree lives: the right
/// sidebar's Files tab, the leading panel, or the stacked region. Its
/// Placement submenu writes `sidebar.filesPanelPlacement` and its Editor
/// submenu writes `fileExplorer.doubleClickAction`, each through the same
/// live setting the Settings window edits, so the header and Settings never
/// disagree.
struct FilesPanelHeaderMenu: View {
    @LiveSetting(\.sidebar.filesPanelPlacement) private var placement
    @LiveSetting(\.fileExplorer.doubleClickAction) private var doubleClickAction
    @LiveSetting(\.fileEditor.terminalEditorCommand) private var terminalEditorCommand

    var body: some View {
        Menu {
            Menu(String(localized: "filesPanel.header.placement", defaultValue: "Placement")) {
                Picker(
                    String(localized: "filesPanel.header.placement", defaultValue: "Placement"),
                    selection: $placement
                ) {
                    ForEach(FilesPanelPlacement.allCases, id: \.self) { option in
                        Text(option.localizedTitle).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Menu(String(localized: "filesPanel.header.editor", defaultValue: "Editor")) {
                Picker(
                    String(localized: "filesPanel.header.editor", defaultValue: "Editor"),
                    selection: $doubleClickAction
                ) {
                    ForEach(editorMenuItems, id: \.action) { item in
                        Text(item.title).tag(item.action)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        } label: {
            Image(systemName: "ellipsis")
                .symbolRenderingMode(.monochrome)
                .frame(
                    width: RightSidebarChromeMetrics.headerIconFrameSize,
                    height: RightSidebarChromeMetrics.headerIconFrameSize
                )
                .frame(
                    width: RightSidebarChromeMetrics.headerControlSize,
                    height: RightSidebarChromeMetrics.headerControlSize
                )
                .foregroundStyle(HeaderChromeIconStyle.foregroundColor)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .safeHelp(String(localized: "filesPanel.header.options.tooltip", defaultValue: "Files options"))
        .accessibilityLabel(String(localized: "filesPanel.header.options.accessibilityLabel", defaultValue: "Files Options"))
        .accessibilityIdentifier("FilesPanel.optionsMenu")
    }

    /// The Editor rows, with the Terminal Editor row naming the editor the
    /// same resolver would run for the current setting and environment.
    private var editorMenuItems: [FilesPanelEditorMenuItem] {
        FilesPanelEditorMenuItems(
            terminalEditor: TerminalEditorCommandResolver(
                configuredCommand: terminalEditorCommand,
                environment: ProcessInfo.processInfo.environment
            ).resolution
        ).items
    }
}
