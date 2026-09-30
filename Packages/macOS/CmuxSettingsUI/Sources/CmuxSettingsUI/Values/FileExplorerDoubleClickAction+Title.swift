import CmuxSettings
import Foundation

public extension FileExplorerDoubleClickAction {
    /// The user-facing name of this choice in the Settings picker.
    ///
    /// - Returns: A localized title, "Native Editor" or "Terminal Editor".
    var localizedTitle: String {
        switch self {
        case .preview:
            return String(localized: "settings.fileExplorer.doubleClickAction.preview", defaultValue: "Native Editor")
        case .terminalEditor:
            return String(localized: "settings.fileExplorer.doubleClickAction.terminalEditor", defaultValue: "Terminal Editor")
        }
    }
}
