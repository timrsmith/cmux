import Foundation

extension Workspace {
    /// Every panel that closes with this workspace, including its Dock's, in the
    /// order the unsaved-changes prompt should list them.
    var closablePanelsIncludingDock: [any Panel] {
        Array(panels.values) + (_dockSplit.map { Array($0.panels.values) } ?? [])
    }
}
