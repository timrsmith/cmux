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
        // Captured as a plain value so the row closure holds no setting wrapper.
        let configuredCommand = terminalEditorCommand
        Menu {
            settingSubmenu(
                String(localized: "filesPanel.header.placement", defaultValue: "Placement"),
                selection: $placement,
                options: FilesPanelPlacement.allCases
            ) { option in
                option.localizedTitle
            }
            settingSubmenu(
                String(localized: "filesPanel.header.editor", defaultValue: "Editor"),
                selection: $doubleClickAction,
                options: FileExplorerDoubleClickAction.allCases
            ) { option in
                FilesPanelEditorMenuItems.title(for: option, configuredCommand: configuredCommand)
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

    /// A submenu holding one inline picker over `options`, bound to a setting.
    private func settingSubmenu<Option: Hashable>(
        _ title: String,
        selection: Binding<Option>,
        options: [Option],
        optionTitle: @escaping (Option) -> String
    ) -> some View {
        Menu(title) {
            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { option in
                    Text(optionTitle(option)).tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}
