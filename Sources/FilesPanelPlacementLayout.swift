import CmuxSettings
import CoreGraphics

/// Pure geometry for the file tree's leading panel, driven by
/// `sidebar.filesPanelPlacement`. With `leading` the file tree is its own
/// panel between the workspace sidebar and the panes; the right sidebar
/// (Find, Changes, Vault, Feed, Dock, Cloud) always stays on the trailing edge.
///
/// `ContentView` owns the live widths and feeds them here; keeping the math in
/// one place means the resizer, the titlebar band, and the header layout
/// cannot drift apart, and the rules are testable without a window.
enum FilesPanelPlacementLayout {
    /// Width the panel opens at before the user resizes it.
    static let defaultWidth: CGFloat = 260
    /// The narrowest the panel's divider can be dragged to. Narrower than the
    /// right sidebar's floor because the panel only hosts the tree.
    static let minimumWidth: CGFloat = 200

    /// Insets the workspace titlebar band applies so its drag/double-click
    /// surface never covers the panel's header on the left nor the right
    /// sidebar's mode bar on the right (see #5099).
    struct TitlebarBandInsets: Equatable {
        var leading: CGFloat
        var trailing: CGFloat

        static let zero = TitlebarBandInsets(leading: 0, trailing: 0)
    }

    /// Whether the panel is laid out at all: the placement is `leading` and
    /// the user has not closed it. The `stacked` placement puts the tree inside
    /// the workspace sidebar instead (`FilesPanelStackedLayout.isStacked`), so
    /// it never docks a leading panel and, like `rightSidebar`, needs no
    /// leading titlebar inset and no header row of its own.
    static func isDocked(placement: FilesPanelPlacement, isFilesPanelVisible: Bool) -> Bool {
        placement == .leading && isFilesPanelVisible
    }

    /// The x position of the panel's resize divider in window content
    /// coordinates. `leadingSidebarWidth` is the workspace sidebar's width when
    /// it is visible and `0` when hidden; the panel always sits right after it.
    static func dividerX(leadingSidebarWidth: CGFloat, filesPanelWidth: CGFloat) -> CGFloat {
        leadingSidebarWidth + filesPanelWidth
    }

    /// The unclamped panel width after dragging its divider by `translation`
    /// points. The panes are to the right, so a rightward drag grows the panel.
    static func draggedWidth(startWidth: CGFloat, translation: CGFloat) -> CGFloat {
        startWidth + translation
    }

    /// Clamps a candidate width to the panel's floor and the caller's cap. The
    /// cap comes from the same dynamic rule the right sidebar uses (window width
    /// minus reserved terminal space, capped by the configured maximum) so the
    /// two tool panels never squeeze the panes out together. A non-finite
    /// candidate lands on the default width.
    static func clampedWidth(_ candidate: CGFloat, maximumWidth: CGFloat) -> CGFloat {
        let sanitizedMaximum = max(minimumWidth, maximumWidth.isFinite ? maximumWidth : minimumWidth)
        guard candidate.isFinite else {
            return max(minimumWidth, min(sanitizedMaximum, defaultWidth))
        }
        return max(minimumWidth, min(sanitizedMaximum, candidate))
    }

    /// Where the titlebar band must stop on each side. The trailing inset is
    /// the right sidebar's width (`0` when hidden), as before. The leading
    /// inset covers both the workspace sidebar and the files panel while the
    /// panel is docked, so the band never swallows clicks on the panel's
    /// header; the workspace sidebar's own titlebar controls live in the AppKit
    /// accessory above the band, so ceding that strip costs nothing. Without a
    /// docked panel the leading inset is `0`, exactly the pre-panel layout.
    static func titlebarBandInsets(
        placement: FilesPanelPlacement,
        isFilesPanelVisible: Bool,
        leadingSidebarWidth: CGFloat,
        filesPanelWidth: CGFloat,
        rightSidebarWidth: CGFloat
    ) -> TitlebarBandInsets {
        let leading = isDocked(placement: placement, isFilesPanelVisible: isFilesPanelVisible)
            ? leadingSidebarWidth + filesPanelWidth
            : 0
        return TitlebarBandInsets(leading: leading, trailing: max(0, rightSidebarWidth))
    }

    /// Whether the panel's header must move onto its own row beneath an empty
    /// titlebar strip. That happens only when the panel touches the window's
    /// leading edge (leading placement with the workspace sidebar hidden): the
    /// traffic lights and the titlebar accessory controls occupy that strip,
    /// and padding the header past them would force the panel far wider than
    /// the user chose. Giving the header its own row keeps the width untouched.
    static func headerNeedsOwnRow(placement: FilesPanelPlacement, isLeadingSidebarVisible: Bool) -> Bool {
        placement == .leading && !isLeadingSidebarVisible
    }
}
