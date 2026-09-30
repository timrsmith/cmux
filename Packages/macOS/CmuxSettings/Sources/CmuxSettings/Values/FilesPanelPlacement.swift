import Foundation

/// Where the file tree lives (`sidebar.filesPanelPlacement`).
///
/// `rightSidebar` (the default) keeps the file tree as the Files tab of the
/// right sidebar, next to Find, Changes, and the other tool panels. `leading`
/// gives the file tree its own panel docked between the workspace sidebar and
/// the panes, IDE style. `stacked` keeps it inside the workspace sidebar,
/// above the workspace list and under the sidebar's titlebar strip, split
/// from the list by a draggable horizontal divider. With either of the last
/// two the right sidebar stays on the right edge and no longer shows a Files
/// tab.
public enum FilesPanelPlacement: String, CaseIterable, Sendable, SettingCodable {
    /// The Files tab of the right sidebar.
    case rightSidebar
    /// A separate panel between the workspace sidebar and the panes.
    case leading
    /// A region of the workspace sidebar, above the workspace list.
    case stacked

    /// Whether the file tree is shown somewhere other than the right sidebar's
    /// Files tab (`leading` or `stacked`), so the right sidebar has no Files tab.
    public var isDetachedFromRightSidebar: Bool {
        self != .rightSidebar
    }
}
