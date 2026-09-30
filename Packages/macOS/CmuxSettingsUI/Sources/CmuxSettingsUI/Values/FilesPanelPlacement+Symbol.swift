import CmuxSettings
import Foundation

public extension FilesPanelPlacement {
    /// The SF Symbol that pictures this placement, shared by the Settings
    /// picker and the Files panel header's Placement submenu.
    ///
    /// Each symbol is a rectangle whose filled part is where the tree
    /// sits: the trailing half for the right sidebar tab, the leading half
    /// for the panel left of the panes, and the top half for the region
    /// above the workspace list.
    ///
    /// - Returns: A system symbol name that renders on every supported macOS
    ///   release, such as `rectangle.trailinghalf.inset.filled`.
    var symbolName: String {
        switch self {
        case .rightSidebar:
            return "rectangle.trailinghalf.inset.filled"
        case .leading:
            return "rectangle.leadinghalf.inset.filled"
        case .stacked:
            return "rectangle.tophalf.inset.filled"
        }
    }
}
