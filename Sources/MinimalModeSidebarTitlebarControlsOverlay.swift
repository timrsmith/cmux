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
    /// The top padding that keeps the controls level with the traffic
    /// lights of `window`, or the default inset before a window is attached.
    /// `ContentView` and `VerticalTabsSidebar` both compute it from the
    /// window they observe, so both strips place the controls the same way.
    @MainActor
    static func topPadding(in window: NSWindow?) -> CGFloat {
        guard let window else {
            return MinimalModeSidebarTitlebarControlsMetrics.topInset
        }
        return minimalModeSidebarTitlebarControlsTopInset(in: window)
    }

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

/// The titlebar strip: the draggable, double-clickable band under the window
/// controls, with the minimal-mode toolbar buttons over its leading edge when
/// the strip has `controls`. `VerticalTabsSidebar` draws it over the top of
/// its list, `StackedFilesPanelSplit` shows it above the Files region while
/// the tree is stacked (so the list below drops its own copy), and
/// `FilesPanelView` shows it without controls above its header when the
/// leading panel sits under the window controls.
struct SidebarTitlebarChromeStrip: View {
    /// The strip's height, the app titlebar height every host lays out with.
    static let height: CGFloat = MinimalModeChromeMetrics.titlebarHeight

    var controls: MinimalModeSidebarTitlebarControlsOverlay? = nil

    var body: some View {
        WindowDragHandleView()
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .background(TitlebarDoubleClickMonitorView())
            .overlay(alignment: .topLeading) {
                if let controls {
                    controls
                }
            }
    }
}
