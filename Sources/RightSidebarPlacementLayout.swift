import CmuxSettings
import CoreGraphics

/// Pure geometry for docking the right sidebar (Files, Find, Dock, and the
/// other tool panels) on either window edge, driven by `sidebar.rightPosition`.
///
/// `ContentView` owns the live widths and feeds them here; keeping the math in
/// one place means the leading and trailing placements cannot drift apart and
/// the rules are testable without a window.
enum RightSidebarPlacementLayout {
    /// Insets the workspace titlebar band applies so its drag/double-click
    /// surface never covers the panel's mode bar (see #5099).
    struct TitlebarBandInsets: Equatable {
        var leading: CGFloat
        var trailing: CGFloat

        static let zero = TitlebarBandInsets(leading: 0, trailing: 0)
    }

    /// Which side of its resize divider the panel sits on. The edge decides
    /// how much of the resize hit band overlaps the panel versus the panes.
    static func resizerEdge(position: RightSidebarPosition) -> SidebarResizeInteraction.Edge {
        switch position {
        case .leading:
            return .leading
        case .trailing:
            return .trailing
        }
    }

    /// The x position of the panel's resize divider in window content
    /// coordinates. `leadingSidebarWidth` is the workspace sidebar's width when
    /// it is visible and `0` when hidden.
    static func dividerX(
        position: RightSidebarPosition,
        totalWidth: CGFloat,
        leadingSidebarWidth: CGFloat,
        rightSidebarWidth: CGFloat
    ) -> CGFloat {
        switch position {
        case .leading:
            return leadingSidebarWidth + rightSidebarWidth
        case .trailing:
            return totalWidth - rightSidebarWidth
        }
    }

    /// The unclamped panel width after dragging its divider by `translation`
    /// points. Dragging toward the panes always grows the panel, whichever
    /// edge it is docked to.
    static func draggedWidth(
        startWidth: CGFloat,
        translation: CGFloat,
        position: RightSidebarPosition
    ) -> CGFloat {
        switch position {
        case .leading:
            return startWidth + translation
        case .trailing:
            return startWidth - translation
        }
    }

    /// Where the titlebar band must stop so it does not swallow clicks on the
    /// panel's mode bar. A hidden panel (`rightSidebarWidth == 0`) needs no
    /// inset. When the panel is leading, the band starts after both sidebars;
    /// the workspace sidebar's own titlebar controls live in the AppKit
    /// accessory above the band, so ceding that strip costs nothing.
    static func titlebarBandInsets(
        position: RightSidebarPosition,
        leadingSidebarWidth: CGFloat,
        rightSidebarWidth: CGFloat
    ) -> TitlebarBandInsets {
        guard rightSidebarWidth > 0 else { return .zero }
        switch position {
        case .leading:
            return TitlebarBandInsets(leading: leadingSidebarWidth + rightSidebarWidth, trailing: 0)
        case .trailing:
            return TitlebarBandInsets(leading: 0, trailing: rightSidebarWidth)
        }
    }

    /// The width the panel actually renders at. When the mode bar carries a
    /// leading inset (see `modeBarLeadingInset`), the panel must grow by that
    /// inset over its configured minimum, or the bar's minimum width exceeds
    /// the panel and the whole content overflows and clips (#right-sidebar
    /// leading dogfood: tree rows cut off with the workspace sidebar hidden).
    static func effectivePanelWidth(
        configuredWidth: CGFloat,
        minimumWidth: CGFloat,
        headerLeadingInset: CGFloat
    ) -> CGFloat {
        guard headerLeadingInset > 0 else { return configuredWidth }
        return max(configuredWidth, minimumWidth + headerLeadingInset)
    }

    /// Extra leading padding for the panel's mode bar. Only needed when the
    /// panel touches the window's leading edge (leading placement with the
    /// workspace sidebar hidden), where the traffic lights or the fullscreen
    /// accessory controls would otherwise sit on top of the first mode button.
    static func modeBarLeadingInset(
        position: RightSidebarPosition,
        isLeadingSidebarVisible: Bool,
        isFullScreen: Bool,
        titlebarLeadingInset: CGFloat,
        fullscreenControlsWidth: CGFloat,
        fullscreenControlsLeadingPadding: CGFloat,
        headerLeadingPadding: CGFloat
    ) -> CGFloat {
        guard position == .leading, !isLeadingSidebarVisible else { return 0 }
        let required: CGFloat
        if isFullScreen {
            required = fullscreenControlsLeadingPadding + fullscreenControlsWidth + 8
        } else {
            required = titlebarLeadingInset
        }
        return max(0, required - headerLeadingPadding)
    }
}
