import CmuxSettings
import CoreGraphics
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavioral coverage for `sidebar.filesPanelPlacement`: the cmux.json parse
/// path that lands the value in managed defaults, and the pure geometry
/// `ContentView` uses to dock the file tree between the workspace sidebar and
/// the panes while the right sidebar stays on the trailing edge.
///
/// The SwiftUI layout itself (HStack order, resizer overlay, titlebar band)
/// is exercised by the tagged dev build; the rules it follows are here.
final class FilesPanelPlacementTests: XCTestCase {
    private let managedKey = SidebarCatalogSection().filesPanelPlacement.userDefaultsKey

    // MARK: - cmux.json parse path

    func testSettingsFileStoreAppliesLeadingFilesPanelPlacement() throws {
        try withCleanManagedDefaults(clearing: [managedKey]) { defaults in
            try loadSettingsFile(
                """
                {
                  "sidebar": {
                    "filesPanelPlacement": "leading"
                  }
                }
                """
            )
            XCTAssertEqual(defaults.string(forKey: managedKey), "leading")
            XCTAssertEqual(
                FilesPanelPlacement.decodeFromUserDefaults(defaults.object(forKey: managedKey)),
                .leading
            )
            XCTAssertEqual(FileExplorerState.filesPanelPlacement(defaults: defaults), .leading)
        }
    }

    func testSettingsFileStoreAppliesRightSidebarFilesPanelPlacement() throws {
        try withCleanManagedDefaults(clearing: [managedKey]) { defaults in
            try loadSettingsFile(
                """
                {
                  "sidebar": {
                    "filesPanelPlacement": "rightSidebar"
                  }
                }
                """
            )
            XCTAssertEqual(defaults.string(forKey: managedKey), "rightSidebar")
            XCTAssertEqual(FileExplorerState.filesPanelPlacement(defaults: defaults), .rightSidebar)
        }
    }

    func testSettingsFileStoreAppliesStackedFilesPanelPlacement() throws {
        try withCleanManagedDefaults(clearing: [managedKey]) { defaults in
            try loadSettingsFile(
                """
                {
                  "sidebar": {
                    "filesPanelPlacement": "stacked"
                  }
                }
                """
            )
            XCTAssertEqual(defaults.string(forKey: managedKey), "stacked")
            XCTAssertEqual(FileExplorerState.filesPanelPlacement(defaults: defaults), .stacked)
            XCTAssertTrue(FilesPanelPlacement.stacked.isDetachedFromRightSidebar)
            XCTAssertTrue(FileExplorerState.filesPanelIsDetached(defaults: defaults))
        }
    }

    func testSettingsFileStoreIgnoresUnknownFilesPanelPlacement() throws {
        try withCleanManagedDefaults(clearing: [managedKey]) { defaults in
            for raw in ["left", "trailing", "Leading", "Stacked", "below"] {
                try loadSettingsFile(
                    """
                    {
                      "sidebar": {
                        "filesPanelPlacement": "\(raw)"
                      }
                    }
                    """
                )
                XCTAssertNil(
                    defaults.object(forKey: managedKey),
                    "\(raw) must not land in managed defaults; the catalog default (rightSidebar) stays in effect"
                )
                XCTAssertEqual(FileExplorerState.filesPanelPlacement(defaults: defaults), .rightSidebar)
            }
        }
    }

    func testSettingsFileStoreIgnoresNonStringFilesPanelPlacement() throws {
        try withCleanManagedDefaults(clearing: [managedKey]) { defaults in
            try loadSettingsFile(
                """
                {
                  "sidebar": {
                    "filesPanelPlacement": true
                  }
                }
                """
            )
            XCTAssertNil(defaults.object(forKey: managedKey))
        }
    }

    func testFilesPanelPlacementIsAdvertisedAsASupportedSettingsPath() {
        XCTAssertTrue(CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("sidebar.filesPanelPlacement"))
        XCTAssertFalse(
            CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("sidebar.rightPosition"),
            "the retired whole-right-sidebar position key must not be advertised"
        )
    }

    // MARK: - Docking

    func testPanelIsDockedOnlyWhenLeadingAndShown() {
        XCTAssertTrue(FilesPanelPlacementLayout.isDocked(placement: .leading, isFilesPanelVisible: true))
        XCTAssertFalse(FilesPanelPlacementLayout.isDocked(placement: .leading, isFilesPanelVisible: false))
        XCTAssertFalse(FilesPanelPlacementLayout.isDocked(placement: .rightSidebar, isFilesPanelVisible: true))
        XCTAssertFalse(FilesPanelPlacementLayout.isDocked(placement: .rightSidebar, isFilesPanelVisible: false))
        // The stacked tree lives inside the workspace sidebar, never as a leading panel.
        XCTAssertFalse(FilesPanelPlacementLayout.isDocked(placement: .stacked, isFilesPanelVisible: true))
        XCTAssertFalse(FilesPanelPlacementLayout.isDocked(placement: .stacked, isFilesPanelVisible: false))
    }

    // MARK: - Stacked split

    func testTreeIsStackedOnlyWhenStackedShownAndTheSidebarIsVisible() {
        XCTAssertTrue(
            FilesPanelStackedLayout.isStacked(placement: .stacked, isFilesPanelVisible: true, isLeadingSidebarVisible: true)
        )
        XCTAssertFalse(
            FilesPanelStackedLayout.isStacked(placement: .stacked, isFilesPanelVisible: false, isLeadingSidebarVisible: true),
            "the user closed the region"
        )
        XCTAssertFalse(
            FilesPanelStackedLayout.isStacked(placement: .stacked, isFilesPanelVisible: true, isLeadingSidebarVisible: false),
            "hiding the sidebar hides the tree with it"
        )
        for placement in [FilesPanelPlacement.rightSidebar, .leading] {
            XCTAssertFalse(
                FilesPanelStackedLayout.isStacked(placement: placement, isFilesPanelVisible: true, isLeadingSidebarVisible: true),
                "\(placement) never stacks the tree above the list"
            )
        }
    }

    func testDraggingTheStackedDividerDownGrowsTheTree() {
        // The tree is above the divider: a downward drag grows the tree and
        // shrinks the list; an upward drag does the opposite.
        XCTAssertEqual(
            FilesPanelStackedLayout.draggedHeight(startHeight: 320, translation: 40),
            360,
            accuracy: 0.001
        )
        XCTAssertEqual(
            FilesPanelStackedLayout.draggedHeight(startHeight: 320, translation: -40),
            280,
            accuracy: 0.001
        )
    }

    func testStackedRegionsExcludeTheTitlebarStripAboveTheTree() {
        // The sidebar's titlebar strip (window controls, toolbar buttons) sits
        // above the tree and belongs to neither region, so the two share the
        // sidebar height minus that strip.
        XCTAssertEqual(
            FilesPanelStackedLayout.regionsHeight(sidebarHeight: 800, topChromeHeight: 38),
            762,
            accuracy: 0.001
        )
        XCTAssertEqual(
            FilesPanelStackedLayout.regionsHeight(sidebarHeight: 20, topChromeHeight: 38),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            FilesPanelStackedLayout.regionsHeight(sidebarHeight: 800, topChromeHeight: -5),
            800,
            accuracy: 0.001
        )
        // An unmeasured sidebar stays unmeasured, so `clampedHeight` keeps
        // applying only the tree's floor.
        XCTAssertTrue(FilesPanelStackedLayout.regionsHeight(sidebarHeight: .infinity, topChromeHeight: 38).isInfinite)
        XCTAssertTrue(FilesPanelStackedLayout.regionsHeight(sidebarHeight: .nan, topChromeHeight: 38).isNaN)
    }

    func testStackedHeightKeepsBothRegionsUsable() {
        XCTAssertEqual(FilesPanelStackedLayout.defaultHeight, 320)
        XCTAssertEqual(FilesPanelStackedLayout.minimumListHeight, 120)
        XCTAssertEqual(FilesPanelStackedLayout.minimumTreeHeight, 160)
        // Inside the window: the tree never drops under its floor, and the
        // list always keeps its minimum below the divider.
        XCTAssertEqual(FilesPanelStackedLayout.clampedHeight(90, availableHeight: 800), 160, accuracy: 0.001)
        XCTAssertEqual(FilesPanelStackedLayout.clampedHeight(750, availableHeight: 800), 680, accuracy: 0.001)
        XCTAssertEqual(FilesPanelStackedLayout.clampedHeight(333, availableHeight: 800), 333, accuracy: 0.001)
        // Exactly enough room for both minimums pins the tree to its floor.
        XCTAssertEqual(FilesPanelStackedLayout.clampedHeight(333, availableHeight: 280), 160, accuracy: 0.001)
    }

    func testStackedHeightSharesAShortSidebarProportionally() {
        // Too short for both minimums: neither region swallows the other; the
        // split follows the ratio of the minimums (160 : 120).
        XCTAssertEqual(FilesPanelStackedLayout.clampedHeight(320, availableHeight: 210), 120, accuracy: 0.001)
        XCTAssertEqual(FilesPanelStackedLayout.clampedHeight(50, availableHeight: 210), 120, accuracy: 0.001)
        XCTAssertEqual(FilesPanelStackedLayout.clampedHeight(320, availableHeight: 70), 40, accuracy: 0.001)
        XCTAssertEqual(FilesPanelStackedLayout.clampedHeight(320, availableHeight: 0), 320, accuracy: 0.001)
    }

    func testStackedHeightSanitizesCorruptAndUnmeasuredInput() {
        // A corrupted persisted height lands on the default.
        XCTAssertEqual(FilesPanelStackedLayout.clampedHeight(.nan, availableHeight: 800), 320, accuracy: 0.001)
        XCTAssertEqual(FilesPanelStackedLayout.clampedHeight(.infinity, availableHeight: 800), 320, accuracy: 0.001)
        // Before the sidebar is measured only the tree's floor applies; the
        // live layout re-clamps once it knows the height.
        XCTAssertEqual(FilesPanelStackedLayout.clampedHeight(90, availableHeight: .infinity), 160, accuracy: 0.001)
        XCTAssertEqual(FilesPanelStackedLayout.clampedHeight(900, availableHeight: .infinity), 900, accuracy: 0.001)
        XCTAssertEqual(FilesPanelStackedLayout.clampedHeight(.nan, availableHeight: .nan), 320, accuracy: 0.001)
    }

    func testStackedPlacementCedesNoLeadingTitlebarStripAndKeepsTheHeaderInOneRow() {
        // Nothing new sits under the window controls: the sidebar's own
        // titlebar strip stays above the tree, so the band behaves exactly as
        // with the right-sidebar placement and the panel header never needs
        // its own row.
        for filesPanelVisible in [true, false] {
            let insets = FilesPanelPlacementLayout.titlebarBandInsets(
                placement: .stacked,
                isFilesPanelVisible: filesPanelVisible,
                leadingSidebarWidth: 240,
                filesPanelWidth: 260,
                rightSidebarWidth: 300
            )
            XCTAssertEqual(insets, .init(leading: 0, trailing: 300), "visible=\(filesPanelVisible)")
        }
        for sidebarVisible in [true, false] {
            XCTAssertFalse(
                FilesPanelPlacementLayout.headerNeedsOwnRow(placement: .stacked, isLeadingSidebarVisible: sidebarVisible)
            )
        }
    }

    // MARK: - Resizer geometry

    func testFilesDividerSitsAfterTheWorkspaceSidebarAndThePanel() {
        XCTAssertEqual(
            FilesPanelPlacementLayout.dividerX(leadingSidebarWidth: 240, filesPanelWidth: 260),
            500,
            accuracy: 0.001
        )
    }

    func testFilesDividerIgnoresAHiddenWorkspaceSidebar() {
        XCTAssertEqual(
            FilesPanelPlacementLayout.dividerX(leadingSidebarWidth: 0, filesPanelWidth: 260),
            260,
            accuracy: 0.001
        )
    }

    func testDraggingTowardThePanesGrowsThePanel() {
        // The panes are to the right, so a rightward drag grows the panel.
        XCTAssertEqual(
            FilesPanelPlacementLayout.draggedWidth(startWidth: 260, translation: 40),
            300,
            accuracy: 0.001
        )
        XCTAssertEqual(
            FilesPanelPlacementLayout.draggedWidth(startWidth: 260, translation: -40),
            220,
            accuracy: 0.001
        )
    }

    func testWidthClampsToTheFloorAndTheCallersCap() {
        XCTAssertEqual(FilesPanelPlacementLayout.minimumWidth, 200)
        XCTAssertEqual(FilesPanelPlacementLayout.defaultWidth, 260)
        XCTAssertEqual(FilesPanelPlacementLayout.clampedWidth(120, maximumWidth: 600), 200, accuracy: 0.001)
        XCTAssertEqual(FilesPanelPlacementLayout.clampedWidth(700, maximumWidth: 600), 600, accuracy: 0.001)
        XCTAssertEqual(FilesPanelPlacementLayout.clampedWidth(333, maximumWidth: 600), 333, accuracy: 0.001)
        // A cap below the floor never squeezes the panel under its minimum.
        XCTAssertEqual(FilesPanelPlacementLayout.clampedWidth(150, maximumWidth: 100), 200, accuracy: 0.001)
        // Non-finite input (a corrupted persisted width) lands on the default width.
        XCTAssertEqual(FilesPanelPlacementLayout.clampedWidth(.nan, maximumWidth: 600), 260, accuracy: 0.001)
        XCTAssertEqual(FilesPanelPlacementLayout.clampedWidth(.infinity, maximumWidth: 600), 260, accuracy: 0.001)
    }

    @MainActor
    func testOcclusionResolverTreatsTheFilesDividerAsALeadingEdgeBand() {
        let resolver = SidebarResizerOcclusionResolver(topmostMouseEventWindowNumber: { _ in 1 })
        let bounds = NSRect(x: 0, y: 0, width: 1_400, height: 800)
        let filesDividerX = FilesPanelPlacementLayout.dividerX(leadingSidebarWidth: 240, filesPanelWidth: 260)
        func contains(_ x: CGFloat, filesPanelVisible: Bool) -> Bool {
            resolver.dividerBandContains(
                point: NSPoint(x: x, y: 400),
                contentBounds: bounds,
                isLeftSidebarVisible: true,
                leftDividerX: 240,
                isRightSidebarVisible: false,
                rightDividerX: 1_400,
                isFilesPanelVisible: filesPanelVisible,
                filesDividerX: filesDividerX
            )
        }
        // Just inside the panel side of the files divider.
        XCTAssertTrue(contains(filesDividerX - 2, filesPanelVisible: true))
        // Just inside the pane side of the files divider.
        XCTAssertTrue(contains(filesDividerX + 2, filesPanelVisible: true))
        XCTAssertFalse(contains(filesDividerX - 2, filesPanelVisible: false), "no band without a docked panel")
        XCTAssertFalse(contains(filesDividerX + 40, filesPanelVisible: true), "pane content past the band is not a divider")
        // The workspace sidebar's own divider still counts.
        XCTAssertTrue(contains(238, filesPanelVisible: true))
    }

    // MARK: - Titlebar band

    func testBandCedesOnlyTheRightSidebarStripWithoutADockedPanel() {
        for placement in FilesPanelPlacement.allCases {
            for filesPanelVisible in [true, false] where !FilesPanelPlacementLayout.isDocked(placement: placement, isFilesPanelVisible: filesPanelVisible) {
                let insets = FilesPanelPlacementLayout.titlebarBandInsets(
                    placement: placement,
                    isFilesPanelVisible: filesPanelVisible,
                    leadingSidebarWidth: 240,
                    filesPanelWidth: 260,
                    rightSidebarWidth: 300
                )
                XCTAssertEqual(insets, .init(leading: 0, trailing: 300), "\(placement) visible=\(filesPanelVisible)")
            }
        }
    }

    func testHiddenRightSidebarNeedsNoTrailingInset() {
        let insets = FilesPanelPlacementLayout.titlebarBandInsets(
            placement: .rightSidebar,
            isFilesPanelVisible: true,
            leadingSidebarWidth: 240,
            filesPanelWidth: 260,
            rightSidebarWidth: 0
        )
        XCTAssertEqual(insets, .zero)
    }

    func testDockedPanelStartsTheBandAfterTheWorkspaceSidebarAndThePanel() {
        let insets = FilesPanelPlacementLayout.titlebarBandInsets(
            placement: .leading,
            isFilesPanelVisible: true,
            leadingSidebarWidth: 240,
            filesPanelWidth: 260,
            rightSidebarWidth: 300
        )
        XCTAssertEqual(insets, .init(leading: 500, trailing: 300), "both tool panels are ceded at once")
    }

    func testDockedPanelBandStartsAfterThePanelWhenTheWorkspaceSidebarIsHidden() {
        let insets = FilesPanelPlacementLayout.titlebarBandInsets(
            placement: .leading,
            isFilesPanelVisible: true,
            leadingSidebarWidth: 0,
            filesPanelWidth: 260,
            rightSidebarWidth: 0
        )
        XCTAssertEqual(insets, .init(leading: 260, trailing: 0))
    }

    // MARK: - Header row

    func testHeaderStaysInTheTitlebarStripWhenTheTreeIsARightSidebarTab() {
        for sidebarVisible in [true, false] {
            XCTAssertFalse(
                FilesPanelPlacementLayout.headerNeedsOwnRow(placement: .rightSidebar, isLeadingSidebarVisible: sidebarVisible),
                "a right-sidebar tab never sits under the window controls (sidebar visible: \(sidebarVisible))"
            )
        }
    }

    func testHeaderStaysInTheTitlebarStripWhenTheWorkspaceSidebarCoversTheWindowControls() {
        XCTAssertFalse(
            FilesPanelPlacementLayout.headerNeedsOwnRow(placement: .leading, isLeadingSidebarVisible: true)
        )
    }

    func testHeaderMovesToItsOwnRowWhenThePanelTouchesTheLeadingEdge() {
        // Regression: padding the header past the window controls forced the
        // panel to minimum-plus-inset and made the divider drag a no-op. The
        // header takes its own row and the panel keeps the configured width.
        XCTAssertTrue(
            FilesPanelPlacementLayout.headerNeedsOwnRow(placement: .leading, isLeadingSidebarVisible: false)
        )
    }
}
