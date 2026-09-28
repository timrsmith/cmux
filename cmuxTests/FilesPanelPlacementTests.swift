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
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"
    private let managedKey = SidebarCatalogSection().filesPanelPlacement.userDefaultsKey

    // MARK: - cmux.json parse path

    func testSettingsFileStoreAppliesLeadingFilesPanelPlacement() throws {
        try withCleanManagedDefaults { defaults in
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
        try withCleanManagedDefaults { defaults in
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

    func testSettingsFileStoreIgnoresUnknownFilesPanelPlacement() throws {
        try withCleanManagedDefaults { defaults in
            for raw in ["left", "trailing", "Leading"] {
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
        try withCleanManagedDefaults { defaults in
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

    // MARK: - Helpers

    private func withCleanManagedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let defaults = UserDefaults.standard
        let keys = [managedKey, settingsFileBackupsDefaultsKey, importedManagedDefaultsKey]
        let previousValues = keys.reduce(into: [String: Any]()) { values, key in
            values[key] = defaults.object(forKey: key)
        }
        defer {
            for key in keys {
                if let value = previousValues[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        try body(defaults)
    }

    private func loadSettingsFile(_ contents: String) throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "files-panel-placement-settings-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try contents.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
    }
}
