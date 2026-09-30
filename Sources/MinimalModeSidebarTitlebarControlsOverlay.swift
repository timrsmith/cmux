import AppKit
import CmuxNotifications
import SwiftUI

struct MinimalModeSidebarTitlebarControlsOverlay: View {
    let unreadModel: SidebarUnreadModel
    let layoutModel: TitlebarControlsLayoutModel
    let leadingInset: CGFloat
    let topPadding: CGFloat
    let onToggleSidebar: () -> Void
    let onToggleNotifications: (NSView?) -> Void
    let onNewTab: () -> Void
    let onFocusHistoryBack: () -> Void
    let onFocusHistoryForward: () -> Void

    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    var body: some View {
        if isMinimalMode {
            HiddenTitlebarSidebarControlsView(
                unreadModel: unreadModel,
                layoutModel: layoutModel,
                onToggleSidebar: onToggleSidebar,
                onToggleNotifications: onToggleNotifications,
                onNewTab: onNewTab,
                onFocusHistoryBack: onFocusHistoryBack,
                onFocusHistoryForward: onFocusHistoryForward
            )
            .padding(.leading, leadingInset)
            .padding(.top, topPadding)
        }
    }
}

extension MinimalModeSidebarTitlebarControlsOverlay {
    /// The overlay as the workspace sidebar wires it (notifications popover,
    /// focus history back and forward), shared by the strip
    /// `VerticalTabsSidebar` draws over its list and the strip
    /// `StackedFilesPanelSplit` shows above a stacked Files region, so both
    /// places keep one set of button behaviors.
    @MainActor
    static func workspaceSidebar(
        unreadModel: SidebarUnreadModel,
        layoutModel: TitlebarControlsLayoutModel,
        leadingInset: CGFloat,
        topPadding: CGFloat,
        tabManager: TabManager,
        onToggleSidebar: @escaping () -> Void,
        onNewTab: @escaping () -> Void
    ) -> MinimalModeSidebarTitlebarControlsOverlay {
        MinimalModeSidebarTitlebarControlsOverlay(
            unreadModel: unreadModel,
            layoutModel: layoutModel,
            leadingInset: leadingInset,
            topPadding: topPadding,
            onToggleSidebar: onToggleSidebar,
            onToggleNotifications: { anchorView in
                AppDelegate.shared?.toggleNotificationsPopover(
                    animated: true,
                    anchorView: anchorView
                )
            },
            onNewTab: onNewTab,
            onFocusHistoryBack: {
                if !tabManager.navigateBack() {
                    NSSound.beep()
                }
            },
            onFocusHistoryForward: {
                if !tabManager.navigateForward() {
                    NSSound.beep()
                }
            }
        )
    }
}

/// The workspace sidebar's titlebar strip on its own: the draggable,
/// double-clickable band under the window controls with the minimal-mode
/// toolbar buttons over its leading edge. `VerticalTabsSidebar` draws the same
/// two layers over the top of its list; this stand-alone strip sits above the
/// Files region while the tree is stacked (`StackedFilesPanelSplit`), so the
/// list below it can drop its own copy.
struct SidebarTitlebarChromeStrip: View {
    let height: CGFloat
    let controls: MinimalModeSidebarTitlebarControlsOverlay

    var body: some View {
        WindowDragHandleView()
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(TitlebarDoubleClickMonitorView())
            .overlay(alignment: .topLeading) {
                controls
            }
    }
}
