import CmuxSettings
import CmuxSettingsUI
import SwiftUI

/// The "…" menu on the Files header, wherever the tree lives: the right
/// sidebar's Files tab, the leading panel, or the stacked region. Show
/// Changes jumps to the right sidebar's Changes tab through the same action
/// the Changes shortcut and the command palette run; the caller decides
/// whether to offer it (`onShowChanges`). The Placement submenu writes
/// `sidebar.filesPanelPlacement` through the same live setting the Settings
/// window edits, so the header and Settings never disagree. Every other file
/// setting (where files open, the terminal editor, the file editor's
/// display) lives in Settings > Files and Editing, which the last item opens.
struct FilesPanelHeaderMenu: View {
    @LiveSetting(\.sidebar.filesPanelPlacement) private var placement
    /// Shows the right sidebar on its Changes tab. `nil` where the item is
    /// not offered: inside that sidebar already (its Files tab, where Changes
    /// is a neighbouring tab), or while the Changes tab is hidden.
    var onShowChanges: (() -> Void)? = nil

    var body: some View {
        let placementTitle = String(localized: "filesPanel.header.placement", defaultValue: "Placement")
        Menu {
            if let onShowChanges {
                Button(action: onShowChanges) {
                    Label(
                        String(localized: "filesPanel.header.showChanges", defaultValue: "Show Changes"),
                        systemImage: RightSidebarMode.changes.symbolName
                    )
                }
                .accessibilityIdentifier("FilesPanel.showChangesMenuItem")
                Divider()
            }
            Menu(placementTitle) {
                Picker(placementTitle, selection: $placement) {
                    ForEach(FilesPanelPlacement.allCases, id: \.self) { option in
                        Label(option.localizedTitle, systemImage: option.symbolName).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Divider()
            Button(String(localized: "filesPanel.header.openSettings", defaultValue: "Files and Editing Settings…")) {
                SettingsWindowPresenter.show(navigationTarget: .filesAndEditing)
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
