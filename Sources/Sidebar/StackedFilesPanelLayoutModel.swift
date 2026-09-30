import Combine
import CoreGraphics
import Foundation

/// Live height of the Files region stacked above the workspace list
/// (`sidebar.filesPanelPlacement` = `stacked`), owned outside ContentView's
/// state for the same reason as `SidebarLayoutModel`: a divider drag must
/// re-evaluate only the frame that applies the height
/// (`StackedFilesPanelHeightFrameModifier`), never the split or the window body.
///
/// `FileExplorerState.filesPanelStackedHeight` is the persisted value this is
/// reconciled with (`PersistedPanelDimensionReconciler`: loaded on appear,
/// written back when a drag ends).
@MainActor
final class StackedFilesPanelLayoutModel: ObservableObject {
    @Published var height: CGFloat
    /// The height when the current divider drag began; `nil` outside a drag.
    /// Not published: it changes only at drag boundaries and drives no layout.
    var dragStartHeight: CGFloat?

    init(height: CGFloat = FilesPanelStackedLayout.defaultHeight) {
        self.height = height
    }

    /// Starts a divider drag: the drag translates from the height on screen,
    /// `height` clamped against `availableHeight`, never the stored value. A
    /// persisted height taller than the regions can show (a window that got
    /// shorter) is displayed clamped, and a drag that started from the stored
    /// value re-clamped to the same height for its first points, a dead zone
    /// as long as the excess.
    func beginDrag(availableHeight: CGFloat) {
        dragStartHeight = FilesPanelStackedLayout.clampedHeight(height, availableHeight: availableHeight)
    }

    /// Applies one drag tick: the start height moved by `translation`
    /// (positive toward the bottom of the window), clamped so both regions
    /// keep their minimum inside `availableHeight`.
    func drag(translation: CGFloat, availableHeight: CGFloat) {
        let startHeight = dragStartHeight
            ?? FilesPanelStackedLayout.clampedHeight(height, availableHeight: availableHeight)
        height = FilesPanelStackedLayout.clampedHeight(
            FilesPanelStackedLayout.draggedHeight(startHeight: startHeight, translation: translation),
            availableHeight: availableHeight
        )
    }

    /// Re-clamps the live height when the regions' height changes (the window
    /// was resized, the sidebar measured), so the value the model holds is the
    /// one on screen. A drag in flight owns the value and is left alone; an
    /// unchanged result writes nothing, so observers see no tick.
    func reclamp(availableHeight: CGFloat) {
        guard dragStartHeight == nil else { return }
        let clamped = FilesPanelStackedLayout.clampedHeight(height, availableHeight: availableHeight)
        guard clamped != height else { return }
        height = clamped
    }

    /// Ends the drag and returns the height to persist.
    @discardableResult
    func endDrag() -> CGFloat {
        dragStartHeight = nil
        return height
    }
}
