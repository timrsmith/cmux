import CmuxSettings
import CoreGraphics

/// Pure geometry for the file tree stacked above the workspace list inside
/// the workspace sidebar (`sidebar.filesPanelPlacement` = `stacked`). The
/// sidebar splits vertically under its titlebar strip: the Files panel on
/// top, the workspace list (with the sidebar footer) below, separated by a
/// horizontal divider the user drags to resize.
///
/// `ContentView` owns the live height and feeds it here, like
/// `FilesPanelPlacementLayout` does for the leading panel's width, so the
/// divider, the persisted height, and the split follow one set of rules that
/// are testable without a window.
enum FilesPanelStackedLayout {
    /// Height of the Files region before the user resizes it.
    static let defaultHeight: CGFloat = 320
    /// The shortest the workspace list may get while the tree is stacked
    /// above it: a few workspace rows plus the sidebar footer.
    static let minimumListHeight: CGFloat = 120
    /// The shortest the Files region may be dragged to: its header plus a
    /// few visible rows of the tree.
    static let minimumTreeHeight: CGFloat = 160
    /// Height of the drag band along the top edge of the workspace list. It
    /// lies inside the list region (over the gap above its first row) so it
    /// never steals clicks from the last visible tree row above the divider.
    static let dividerHitHeight: CGFloat = 8

    /// Whether the tree is laid out above the workspace list at all: the
    /// placement is `stacked`, the user has not closed the panel, and the
    /// workspace sidebar that hosts it is shown. Hiding the sidebar hides the
    /// tree with it; showing the sidebar brings it back.
    static func isStacked(
        placement: FilesPanelPlacement,
        isFilesPanelVisible: Bool,
        isLeadingSidebarVisible: Bool
    ) -> Bool {
        placement == .stacked && isFilesPanelVisible && isLeadingSidebarVisible
    }

    /// The height the two regions share: the sidebar's height minus the
    /// titlebar strip above the tree (window controls and toolbar buttons),
    /// which belongs to neither region. Never negative.
    static func regionsHeight(sidebarHeight: CGFloat, topChromeHeight: CGFloat) -> CGFloat {
        guard sidebarHeight.isFinite else { return sidebarHeight }
        return max(0, sidebarHeight - max(0, topChromeHeight))
    }

    /// The unclamped Files height after dragging the divider by `translation`
    /// points, positive toward the bottom of the window. The tree is above the
    /// divider, so a downward drag grows the tree and shrinks the list.
    static func draggedHeight(startHeight: CGFloat, translation: CGFloat) -> CGFloat {
        startHeight + translation
    }

    /// Clamps a candidate Files height so both regions keep a usable minimum
    /// inside `availableHeight` (the height the two regions share, see
    /// `regionsHeight`). When that is too short for both minimums, the two
    /// shrink together in the ratio of their minimums instead of one region
    /// swallowing the other. A non-finite candidate (a corrupted persisted
    /// height) lands on the default height; a non-finite or non-positive
    /// available height (no window yet) only applies the tree's floor, and
    /// the live layout re-clamps once measured.
    static func clampedHeight(_ candidate: CGFloat, availableHeight: CGFloat) -> CGFloat {
        let resolvedCandidate = candidate.isFinite ? candidate : defaultHeight
        guard availableHeight.isFinite, availableHeight > 0 else {
            return max(minimumTreeHeight, resolvedCandidate)
        }
        let minimumTotal = minimumListHeight + minimumTreeHeight
        guard availableHeight >= minimumTotal else {
            return (availableHeight * minimumTreeHeight / minimumTotal).rounded()
        }
        return max(minimumTreeHeight, min(availableHeight - minimumListHeight, resolvedCandidate))
    }
}
