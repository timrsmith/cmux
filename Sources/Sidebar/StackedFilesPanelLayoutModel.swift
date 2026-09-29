import Combine
import CoreGraphics
import Foundation

/// Live height of the Files region stacked under the workspace list
/// (`sidebar.filesPanelPlacement` = `stacked`), owned outside ContentView's
/// state for the same reason as `SidebarLayoutModel`: a divider drag must
/// re-evaluate only the split that applies the height, never the window body.
///
/// `FileExplorerState.filesPanelStackedHeight` is the persisted value this is
/// reconciled with (loaded on appear, written back when a drag ends).
@MainActor
final class StackedFilesPanelLayoutModel: ObservableObject {
    @Published var height: CGFloat
    /// The height when the current divider drag began; `nil` outside a drag.
    /// Not published: it changes only at drag boundaries and drives no layout.
    var dragStartHeight: CGFloat?

    init(height: CGFloat = FilesPanelStackedLayout.defaultHeight) {
        self.height = height
    }
}
