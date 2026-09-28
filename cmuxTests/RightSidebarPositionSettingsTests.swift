import CmuxSettings
import CoreGraphics
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavioral coverage for `sidebar.rightPosition`: the cmux.json parse path
/// that lands the value in managed defaults, and the pure placement geometry
/// `ContentView` uses to dock the right sidebar on either window edge.
///
/// The SwiftUI layout itself (HStack order, resizer overlay, titlebar band)
/// is exercised by the tagged dev build; the rules it follows are here.
final class RightSidebarPositionSettingsTests: XCTestCase {
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"
    private let managedKey = SidebarCatalogSection().rightPosition.userDefaultsKey

    // MARK: - cmux.json parse path

    func testSettingsFileStoreAppliesLeadingRightSidebarPosition() throws {
        try withCleanManagedDefaults { defaults in
            try loadSettingsFile(
                """
                {
                  "sidebar": {
                    "rightPosition": "leading"
                  }
                }
                """
            )
            XCTAssertEqual(defaults.string(forKey: managedKey), "leading")
            XCTAssertEqual(
                RightSidebarPosition.decodeFromUserDefaults(defaults.object(forKey: managedKey)),
                .leading
            )
        }
    }

    func testSettingsFileStoreAppliesTrailingRightSidebarPosition() throws {
        try withCleanManagedDefaults { defaults in
            try loadSettingsFile(
                """
                {
                  "sidebar": {
                    "rightPosition": "trailing"
                  }
                }
                """
            )
            XCTAssertEqual(defaults.string(forKey: managedKey), "trailing")
        }
    }

    func testSettingsFileStoreIgnoresUnknownRightSidebarPosition() throws {
        try withCleanManagedDefaults { defaults in
            try loadSettingsFile(
                """
                {
                  "sidebar": {
                    "rightPosition": "left"
                  }
                }
                """
            )
            XCTAssertNil(
                defaults.object(forKey: managedKey),
                "an unknown value must not land in managed defaults; the catalog default (trailing) stays in effect"
            )
        }
    }

    func testSettingsFileStoreIgnoresNonStringRightSidebarPosition() throws {
        try withCleanManagedDefaults { defaults in
            try loadSettingsFile(
                """
                {
                  "sidebar": {
                    "rightPosition": true
                  }
                }
                """
            )
            XCTAssertNil(defaults.object(forKey: managedKey))
        }
    }

    func testRightSidebarPositionIsAdvertisedAsASupportedSettingsPath() {
        XCTAssertTrue(CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("sidebar.rightPosition"))
    }

    // MARK: - Resizer geometry

    func testTrailingPlacementKeepsTheDividerAtTheWindowsRightEdge() {
        let dividerX = RightSidebarPlacementLayout.dividerX(
            position: .trailing,
            totalWidth: 1_400,
            leadingSidebarWidth: 240,
            rightSidebarWidth: 300
        )
        XCTAssertEqual(dividerX, 1_100, accuracy: 0.001)
        XCTAssertEqual(RightSidebarPlacementLayout.resizerEdge(position: .trailing), .trailing)
    }

    func testLeadingPlacementPutsTheDividerAfterBothSidebars() {
        let dividerX = RightSidebarPlacementLayout.dividerX(
            position: .leading,
            totalWidth: 1_400,
            leadingSidebarWidth: 240,
            rightSidebarWidth: 300
        )
        XCTAssertEqual(dividerX, 540, accuracy: 0.001)
        XCTAssertEqual(RightSidebarPlacementLayout.resizerEdge(position: .leading), .leading)
    }

    func testLeadingPlacementDividerIgnoresAHiddenWorkspaceSidebar() {
        let dividerX = RightSidebarPlacementLayout.dividerX(
            position: .leading,
            totalWidth: 1_400,
            leadingSidebarWidth: 0,
            rightSidebarWidth: 300
        )
        XCTAssertEqual(dividerX, 300, accuracy: 0.001)
    }

    func testDraggingTowardThePanesGrowsThePanelOnEitherEdge() {
        // Trailing edge: the panes are to the left, so a leftward drag grows it.
        XCTAssertEqual(
            RightSidebarPlacementLayout.draggedWidth(startWidth: 300, translation: -40, position: .trailing),
            340,
            accuracy: 0.001
        )
        XCTAssertEqual(
            RightSidebarPlacementLayout.draggedWidth(startWidth: 300, translation: 40, position: .trailing),
            260,
            accuracy: 0.001
        )
        // Leading edge: the panes are to the right, so a rightward drag grows it.
        XCTAssertEqual(
            RightSidebarPlacementLayout.draggedWidth(startWidth: 300, translation: 40, position: .leading),
            340,
            accuracy: 0.001
        )
        XCTAssertEqual(
            RightSidebarPlacementLayout.draggedWidth(startWidth: 300, translation: -40, position: .leading),
            260,
            accuracy: 0.001
        )
    }

    // MARK: - Titlebar band

    func testHiddenPanelNeedsNoTitlebarBandInset() {
        for position in RightSidebarPosition.allCases {
            let insets = RightSidebarPlacementLayout.titlebarBandInsets(
                position: position,
                leadingSidebarWidth: 240,
                rightSidebarWidth: 0
            )
            XCTAssertEqual(insets, .zero, "\(position)")
        }
    }

    func testTrailingPlacementCedesOnlyTheTrailingStripToThePanel() {
        let insets = RightSidebarPlacementLayout.titlebarBandInsets(
            position: .trailing,
            leadingSidebarWidth: 240,
            rightSidebarWidth: 300
        )
        XCTAssertEqual(insets, .init(leading: 0, trailing: 300))
    }

    func testLeadingPlacementStartsTheBandAfterBothSidebars() {
        let insets = RightSidebarPlacementLayout.titlebarBandInsets(
            position: .leading,
            leadingSidebarWidth: 240,
            rightSidebarWidth: 300
        )
        XCTAssertEqual(insets, .init(leading: 540, trailing: 0))
    }

    func testLeadingPlacementBandStartsAfterThePanelWhenTheWorkspaceSidebarIsHidden() {
        let insets = RightSidebarPlacementLayout.titlebarBandInsets(
            position: .leading,
            leadingSidebarWidth: 0,
            rightSidebarWidth: 300
        )
        XCTAssertEqual(insets, .init(leading: 300, trailing: 0))
    }

    // MARK: - Mode bar row

    func testModeBarStaysInTheTitlebarStripOnTheTrailingEdge() {
        for sidebarVisible in [true, false] {
            XCTAssertFalse(
                RightSidebarPlacementLayout.modeBarNeedsOwnRow(position: .trailing, isLeadingSidebarVisible: sidebarVisible),
                "trailing placement never sits under the window controls (sidebar visible: \(sidebarVisible))"
            )
        }
    }

    func testModeBarStaysInTheTitlebarStripWhenTheWorkspaceSidebarCoversTheWindowControls() {
        XCTAssertFalse(
            RightSidebarPlacementLayout.modeBarNeedsOwnRow(position: .leading, isLeadingSidebarVisible: true)
        )
    }

    func testModeBarMovesToItsOwnRowWhenThePanelTouchesTheLeadingEdge() {
        // Regression: padding the bar past the window controls forced the panel
        // to minimum-plus-inset (about 430pt) and made the divider drag a no-op.
        // The bar now takes its own row and the panel keeps the configured width.
        XCTAssertTrue(
            RightSidebarPlacementLayout.modeBarNeedsOwnRow(position: .leading, isLeadingSidebarVisible: false)
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
            "right-sidebar-position-settings-\(UUID().uuidString)",
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
