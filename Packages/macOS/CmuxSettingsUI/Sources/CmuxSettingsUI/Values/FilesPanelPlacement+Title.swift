import CmuxSettings
import Foundation

public extension FilesPanelPlacement {
    /// The user-facing name of this placement, shared by the Settings picker
    /// and the Files panel's header menu so both surfaces name the choices
    /// identically.
    ///
    /// - Returns: A localized title such as "In Right Sidebar", "Left of
    ///   Panes", or "Below Workspaces".
    var localizedTitle: String {
        switch self {
        case .rightSidebar:
            return String(localized: "settings.sidebar.filesPanelPlacement.rightSidebar", defaultValue: "In Right Sidebar")
        case .leading:
            return String(localized: "settings.sidebar.filesPanelPlacement.leading", defaultValue: "Left of Panes")
        case .stacked:
            return String(localized: "settings.sidebar.filesPanelPlacement.stacked", defaultValue: "Below Workspaces")
        }
    }
}
