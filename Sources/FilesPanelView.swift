import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import SwiftUI

/// The file tree as its own panel, docked between the workspace sidebar and
/// the panes when `sidebar.filesPanelPlacement` is `leading`.
///
/// Hosts the same `FileExplorerPanelView` (same store and state) the right
/// sidebar's Files tab uses, so the tree, its root sync, search, hidden-file
/// toggle, and keyboard focus routing are shared; `FileExplorerPanelView`
/// registers itself with `MainWindowFocusController` as the window's `.files`
/// host, which is what lets `cmux right-sidebar files`, Ctrl+1, and the
/// command palette land here instead of in the right sidebar. The header
/// mirrors the right sidebar's Files chrome (open-as-pane and close controls
/// on a titlebar-height, draggable bar).
struct FilesPanelView: View {
    @ObservedObject var fileExplorerStore: FileExplorerStore
    @ObservedObject var fileExplorerState: FileExplorerState
    let titlebarHeight: CGFloat
    /// True when the panel touches the window's leading edge (workspace
    /// sidebar hidden): the traffic lights and titlebar accessory controls own
    /// that strip, so the header moves onto its own row beneath an empty,
    /// draggable titlebar-height strip (`FilesPanelPlacementLayout.headerNeedsOwnRow`).
    let headerBelowTitlebarStrip: Bool
    let windowAppearance: WindowAppearanceSnapshot
    let onOpenFilePreview: (String) -> Void
    /// Shows the right sidebar on its Changes tab (the same action the
    /// Changes shortcut and the command palette run), or `nil` to leave the
    /// item out of the header menu while that tab is hidden. With the tree
    /// docked outside the sidebar the two are no longer a tab switch apart,
    /// so the menu is how the tree reaches Changes.
    let onShowChanges: (() -> Void)?
    let onOpenAsPane: () -> Void
    let onClose: () -> Void

    var body: some View {
        // Leading alignment throughout: if the header ever reports a minimum
        // width wider than the panel, the overflow must fall off the trailing
        // edge instead of the default centering clipping the tree's leading columns.
        VStack(alignment: .leading, spacing: 0) {
            if headerBelowTitlebarStrip {
                // The window controls own this strip; keep it draggable and empty.
                titlebarStrip
            }
            header
                .rightSidebarChromeBottomBorder(
                    backgroundColor: windowAppearance.resolvedChromeBackgroundColor
                )
            FileExplorerPanelView(
                store: fileExplorerStore,
                state: fileExplorerState,
                onOpenFilePreview: onOpenFilePreview,
                presentation: .files
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Same resolved cmux scheme as the window and the other sidebars so
        // the AppKit-backed rows match the chrome around them.
        .environment(\.colorScheme, windowAppearance.resolvedColorScheme)
        .accessibilityIdentifier("FilesPanel")
    }

    /// An empty titlebar-height strip shown above the header when the panel
    /// sits under the window controls, so those controls never overlap the
    /// header buttons and the panel keeps the width the user chose. It drags
    /// the window and handles titlebar double-click like the header does.
    private var titlebarStrip: some View {
        SidebarTitlebarChromeStrip()
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }

    private var header: some View {
        ZStack {
            WindowDragHandleView()

            HStack(spacing: RightSidebarChromeMetrics.headerControlSpacing) {
                HStack(spacing: RightSidebarChromeMetrics.contentIconTextSpacing) {
                    Image(systemName: RightSidebarMode.files.symbolName)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: RightSidebarChromeMetrics.contentIconFrameSize, alignment: .center)
                    Text(RightSidebarMode.files.label)
                        .cmuxFont(size: 12, weight: .semibold)
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.leading, RightSidebarChromeMetrics.controlHorizontalPadding)
                .allowsHitTesting(false)
                .accessibilityIdentifier("FilesPanel.title")
                Spacer(minLength: 0)
                FilesPanelHeaderMenu(onShowChanges: onShowChanges)
                openAsPaneButton
                closeButton
            }
        }
        .rightSidebarChromeBar(
            leadingPadding: RightSidebarChromeMetrics.headerLeadingPadding,
            trailingPadding: RightSidebarChromeMetrics.headerTrailingPadding,
            height: titlebarHeight
        )
        .background(TitlebarDoubleClickMonitorView())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("FilesPanelHeader")
    }

    private var openAsPaneButton: some View {
        Button(action: onOpenAsPane) {
            HeaderChromeIconStyle.symbol("rectangle.split.2x1")
        }
        .buttonStyle(RightSidebarHeaderIconButtonStyle(iconGeometryKeyPrefix: "filesPanelHeaderOpenAsPaneIcon"))
        .frame(
            width: RightSidebarChromeMetrics.headerControlSize,
            height: RightSidebarChromeMetrics.headerControlSize
        )
        .rightSidebarHeaderControlAlignment()
        .safeHelp(String(localized: "rightSidebar.openAsPane.tooltip", defaultValue: "Open as pane"))
        .accessibilityLabel(
            String.localizedStringWithFormat(
                String(localized: "rightSidebar.openAsPane.accessibilityLabel", defaultValue: "Open %@ as Pane"),
                RightSidebarMode.files.label
            )
        )
        .accessibilityIdentifier("FilesPanel.openAsPaneButton")
        .titlebarInteractiveControl()
    }

    private var closeButton: some View {
        Button(action: onClose) {
            HeaderChromeIconStyle.symbol("xmark")
        }
        .buttonStyle(RightSidebarHeaderIconButtonStyle(iconGeometryKeyPrefix: "filesPanelHeaderCloseIcon"))
        .frame(
            width: RightSidebarChromeMetrics.headerControlSize,
            height: RightSidebarChromeMetrics.headerControlSize
        )
        .rightSidebarHeaderControlAlignment()
        .safeHelp(String(localized: "filesPanel.close.tooltip", defaultValue: "Close Files panel"))
        .accessibilityLabel(String(localized: "filesPanel.close.accessibilityLabel", defaultValue: "Close Files Panel"))
        .accessibilityIdentifier("FilesPanel.closeButton")
        .titlebarInteractiveControl()
    }
}
