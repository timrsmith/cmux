import AppKit
import CmuxAppKitSupportUI
import SwiftUI

/// The workspace sidebar split vertically for `sidebar.filesPanelPlacement`
/// = `stacked`: the sidebar's titlebar strip on top (window controls and
/// toolbar buttons), the Files panel under it, a horizontal divider that the
/// user drags to resize, and the workspace list with the sidebar footer at
/// the bottom.
///
/// The list normally draws the titlebar strip itself, over the top of its
/// scroll area (`VerticalTabsSidebar.hostsTitlebarChrome`). While the tree is
/// stacked above it the parent hands that strip to this split as `topChrome`
/// and tells the list not to draw it, so the strip stays at the top of the
/// sidebar and the tree never slides under the window controls. With the
/// region closed the split shows only the list, which draws its own strip
/// again.
///
/// The Files height comes from `StackedFilesPanelLayoutModel`, which this
/// view holds UNOBSERVED, like ContentView holds `SidebarLayoutModel`: the
/// parent builds `topChrome`, `panel`, and `list` once, and only
/// `StackedFilesPanelHeightFrameModifier` observes the model, so a divider
/// drag tick re-applies one frame over the already-built panel instead of
/// re-running this body (and with it the list diff and the panel's
/// `onAppear`/`onChange` closures). The height is re-clamped against the
/// measured sidebar height on every layout pass
/// (`FilesPanelStackedLayout.clampedHeight`), so a window that gets shorter
/// after the user resized the split still keeps both regions usable. The
/// divider uses the same native tracking loop as the vertical sidebar
/// dividers (`SidebarDividerTracker`), whose AppKit cursor rect shows the
/// vertical resize cursor while hovering.
struct StackedFilesPanelSplit<TopChrome: View, Panel: View, List: View>: View {
    /// Deliberately NOT observed; the divider callbacks read and write it
    /// outside any body, and the frame modifier alone tracks its ticks.
    let layout: StackedFilesPanelLayoutModel
    /// Whether the Files region is laid out (`FilesPanelStackedLayout.isStacked`).
    /// The split stays mounted with only the list while it is not, so closing
    /// the region or hiding and re-showing the sidebar never changes the
    /// list's view identity (the AppKit table must not cold-start).
    let showsPanel: Bool
    /// Height of `topChrome`, the sidebar's titlebar strip; excluded from the
    /// height the two regions share (`FilesPanelStackedLayout.regionsHeight`).
    let topChromeHeight: CGFloat
    let chromeBackgroundColor: NSColor
    /// Called with the clamped height when a divider drag ends, for persisting.
    let onHeightCommitted: (CGFloat) -> Void
    /// The sidebar's titlebar strip, shown above the tree while it is stacked.
    let topChrome: TopChrome
    let panel: Panel
    let list: List

    var body: some View {
        GeometryReader { proxy in
            let regionsHeight = FilesPanelStackedLayout.regionsHeight(
                sidebarHeight: proxy.size.height,
                topChromeHeight: topChromeHeight
            )
            VStack(spacing: 0) {
                if showsPanel {
                    topChrome
                        .frame(maxWidth: .infinity)
                        .frame(height: topChromeHeight)
                    panel
                        .frame(maxWidth: .infinity)
                        .modifier(StackedFilesPanelHeightFrameModifier(layout: layout, availableHeight: regionsHeight))
                        .clipped()
                }
                list
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .overlay(alignment: .top) {
                        if showsPanel {
                            WindowChromeBorder(
                                orientation: .horizontal,
                                backgroundColor: chromeBackgroundColor
                            )
                        }
                    }
                    .overlay(alignment: .top) {
                        if showsPanel {
                            divider(availableHeight: regionsHeight)
                        }
                    }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    /// The drag band along the top edge of the workspace list, over the gap
    /// above its first row so the last visible tree row above keeps its full
    /// hit area.
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

/// `.frame(height:)` for the stacked Files region from the layout model, the
/// `SidebarWidthFrameModifier` pattern: the only observer of
/// `StackedFilesPanelLayoutModel`, so a divider tick re-evaluates just this
/// frame application over the panel the parent already built.
struct StackedFilesPanelHeightFrameModifier: ViewModifier {
    @ObservedObject var layout: StackedFilesPanelLayoutModel
    /// The height the two regions share, which the tree height is clamped against.
    let availableHeight: CGFloat

    func body(content: Content) -> some View {
        content.frame(
            height: FilesPanelStackedLayout.clampedHeight(layout.height, availableHeight: availableHeight),
            alignment: .topLeading
        )
    }
}
