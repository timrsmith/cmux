import Foundation

/// Which edge of the window the right sidebar (Files, Find, Dock, and the other
/// tool panels) is docked to. `trailing` keeps it on the right edge, after the
/// panes; `leading` moves it between the workspace sidebar and the panes so the
/// file tree sits next to the workspace list.
public enum RightSidebarPosition: String, CaseIterable, Sendable, SettingCodable {
    /// Between the workspace sidebar and the panes.
    case leading
    /// The right edge of the window, after the panes.
    case trailing
}
