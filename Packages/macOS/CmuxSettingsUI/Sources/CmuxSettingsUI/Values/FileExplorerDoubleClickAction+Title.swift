import CmuxSettings
import Foundation

public extension FileExplorerDoubleClickAction {
    /// The user-facing name of this choice, shared by the Settings picker and
    /// the Files panel header's Editor submenu so both surfaces name the
    /// options identically.
    ///
    /// - Returns: A localized title such as "Native Editor", "Terminal
    ///   Editor", "Default App", or "Preferred Editor App".
    var localizedTitle: String {
        switch self {
        case .preview:
            return String(localized: "settings.fileExplorer.doubleClickAction.preview", defaultValue: "Native Editor")
        case .terminalEditor:
            return String(localized: "settings.fileExplorer.doubleClickAction.terminalEditor", defaultValue: "Terminal Editor")
        case .defaultEditor:
            return String(localized: "settings.fileExplorer.doubleClickAction.defaultEditor", defaultValue: "Default App")
        case .preferredEditor:
            return String(localized: "settings.fileExplorer.doubleClickAction.preferredEditor", defaultValue: "Preferred Editor App")
        }
    }
}
