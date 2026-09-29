import AppKit
import CmuxAppKitSupportUI
import SwiftUI

/// The workspace sidebar split vertically for `sidebar.filesPanelPlacement`
/// = `stacked`: the workspace list on top, the Files panel below, and a
/// horizontal divider between them that the user drags to resize.
///
/// The Files height comes from `StackedFilesPanelLayoutModel`, so a divider
/// drag re-evaluates only this view. The height is re-clamped against the
/// measured sidebar height on every layout pass
/// (`FilesPanelStackedLayout.clampedHeight`), so a window that gets shorter
/// after the user resized the split still keeps both regions usable. The
/// divider uses the same native tracking loop as the vertical sidebar
/// dividers (`SidebarDividerTracker`), whose AppKit cursor rect shows the
/// vertical resize cursor while hovering.
struct StackedFilesPanelSplit<List: View, Panel: View>: View {
    @ObservedObject var layout: StackedFilesPanelLayoutModel
    /// Whether the Files region is laid out (`FilesPanelStackedLayout.isStacked`).
    /// The split stays mounted with only the list while it is not, so closing
    /// the region or hiding and re-showing the sidebar never changes the
    /// list's view identity (the AppKit table must not cold-start).
    let showsPanel: Bool
    let chromeBackgroundColor: NSColor
    /// Called with the clamped height when a divider drag ends, for persisting.
    let onHeightCommitted: (CGFloat) -> Void
    @ViewBuilder let list: () -> List
    @ViewBuilder let panel: () -> Panel

    var body: some View {
        GeometryReader { proxy in
            let availableHeight = proxy.size.height
            let treeHeight = FilesPanelStackedLayout.clampedHeight(layout.height, availableHeight: availableHeight)
            VStack(spacing: 0) {
                list()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if showsPanel {
                    panel()
                        .frame(maxWidth: .infinity)
                        .frame(height: treeHeight, alignment: .topLeading)
                        .clipped()
                        .overlay(alignment: .top) {
                            WindowChromeBorder(
                                orientation: .horizontal,
                                backgroundColor: chromeBackgroundColor
                            )
                        }
                        .overlay(alignment: .top) {
                            divider(availableHeight: availableHeight)
                        }
                }
            }
            .frame(width: proxy.size.width, height: availableHeight, alignment: .topLeading)
        }
    }

    /// The drag band along the top edge of the Files region, over the top of
    /// its header bar so the last workspace row above keeps its full hit area.
    private func divider(availableHeight: CGFloat) -> some View {
        SidebarDividerTracker(
            axis: .vertical,
            onBegan: {
                layout.dragStartHeight = layout.height
            },
            onChanged: { translation in
                let startHeight = layout.dragStartHeight ?? layout.height
                let nextHeight = FilesPanelStackedLayout.clampedHeight(
                    FilesPanelStackedLayout.draggedHeight(startHeight: startHeight, translation: translation),
                    availableHeight: availableHeight
                )
                withTransaction(Transaction(animation: nil)) {
                    layout.height = nextHeight
                }
            },
            onEnded: {
                layout.dragStartHeight = nil
                onHeightCommitted(layout.height)
            }
        )
        .frame(maxWidth: .infinity)
        .frame(height: FilesPanelStackedLayout.dividerHitHeight)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "filesPanel.stackedDivider.accessibilityLabel", defaultValue: "Resize Files Panel"))
        .accessibilityIdentifier("FilesPanelStackedResizer")
    }
}
