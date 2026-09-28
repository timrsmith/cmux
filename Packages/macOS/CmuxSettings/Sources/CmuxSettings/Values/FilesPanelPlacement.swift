import Foundation

/// Where the file tree lives (`sidebar.filesPanelPlacement`).
///
/// `rightSidebar` (the default) keeps the file tree as the Files tab of the
/// right sidebar, next to Find, Changes, and the other tool panels. `leading`
/// gives the file tree its own panel docked between the workspace sidebar and
/// the panes, IDE style; the right sidebar stays on the right edge and no
/// longer shows a Files tab.
public enum FilesPanelPlacement: String, CaseIterable, Sendable, SettingCodable {
    /// The Files tab of the right sidebar.
    case rightSidebar
    /// A separate panel between the workspace sidebar and the panes.
    case leading
}
