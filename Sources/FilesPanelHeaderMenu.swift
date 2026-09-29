import CmuxSettings
import CmuxSettingsUI
import SwiftUI

/// The "…" menu on the Files header, wherever the tree lives: the right
/// sidebar's Files tab, the leading panel, or the stacked region. Its
/// Placement submenu writes `sidebar.filesPanelPlacement` through the same
/// live setting the Settings window edits, so moving the tree never leaves
/// Settings and the header disagreeing.
struct FilesPanelHeaderMenu: View {
    @LiveSetting(\.sidebar.filesPanelPlacement) private var placement

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
}
