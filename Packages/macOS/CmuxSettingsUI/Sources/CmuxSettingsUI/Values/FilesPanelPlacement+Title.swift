import CmuxSettings
import Foundation

public extension FilesPanelPlacement {
    /// The user-facing name of this placement, shared by the Settings picker
    /// and the Files panel's header menu so both surfaces name the choices
    /// identically.
    ///
    /// - Returns: A localized title such as "Right Sidebar", "Left Sidebar",
    ///   or "Stacked".
    var localizedTitle: String {
        switch self {
        case .rightSidebar:
            return String(localized: "settings.sidebar.filesPanelPlacement.rightSidebar", defaultValue: "Right Sidebar")
        case .leading:
            return String(localized: "settings.sidebar.filesPanelPlacement.leading", defaultValue: "Left Sidebar")
        case .stacked:
            return String(localized: "settings.sidebar.filesPanelPlacement.stacked", defaultValue: "Stacked")
        }
    }
}
