import Foundation
import XCTest
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class FileExplorerStateModePersistenceTests: XCTestCase {
    private let modeKey = "rightSidebar.mode"
    private let customSidebarNameKey = "rightSidebar.customSidebarName"
    private let feedEnabledKey = RightSidebarBetaFeatureSettings.feedEnabledKey
    private let legacyDockBetaKey = "rightSidebar.beta.dock.enabled"
    private let filesPanelPlacementKey = SidebarCatalogSection().filesPanelPlacement.userDefaultsKey
    private let filesPanelVisibleKey = FileExplorerState.filesPanelVisibleKey

    func testDisabledFeedStoredModeFallsBackToFiles() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(RightSidebarMode.feed.rawValue, forKey: modeKey)
            defaults.set(false, forKey: feedEnabledKey)

            let state = FileExplorerState()

            XCTAssertEqual(state.mode, .files)
            XCTAssertEqual(defaults.string(forKey: modeKey), RightSidebarMode.files.rawValue)
        }
    }

    func testEnabledFeedStoredModeSurvives() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(RightSidebarMode.feed.rawValue, forKey: modeKey)
            defaults.set(true, forKey: feedEnabledKey)

            let state = FileExplorerState()

            XCTAssertEqual(state.mode, .feed)
            XCTAssertEqual(defaults.string(forKey: modeKey), RightSidebarMode.feed.rawValue)
        }
    }

    func testModeSetterClampsUnavailableFeedButAllowsDock() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(false, forKey: feedEnabledKey)
            let state = FileExplorerState()

            state.mode = .feed
            XCTAssertEqual(state.mode, .files)
            XCTAssertEqual(defaults.string(forKey: modeKey), RightSidebarMode.files.rawValue)

            state.mode = .dock
            XCTAssertEqual(state.mode, .dock)
            XCTAssertEqual(defaults.string(forKey: modeKey), RightSidebarMode.dock.rawValue)
        }
    }

    func testStoredLegacyDockOptOutIsIgnored() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(false, forKey: legacyDockBetaKey)
            let state = FileExplorerState()

            state.mode = .dock
            state.refreshModeAvailability()
            XCTAssertEqual(state.mode, .dock)
            XCTAssertEqual(defaults.string(forKey: modeKey), RightSidebarMode.dock.rawValue)
        }
    }

    func testStoredCustomSidebarModeFallsBackToFilesWhenBetaDisabled() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            let customSidebarsKey = BetaFeaturesCatalogSection().customSidebars.userDefaultsKey
            let previous = defaults.object(forKey: customSidebarsKey)
            defaults.set(false, forKey: customSidebarsKey)
            defer {
                if let previous {
                    defaults.set(previous, forKey: customSidebarsKey)
                } else {
                    defaults.removeObject(forKey: customSidebarsKey)
                }
            }
            defaults.set(RightSidebarMode.customSidebar.rawValue, forKey: modeKey)
            defaults.set("status-board", forKey: customSidebarNameKey)

            let state = FileExplorerState()

            XCTAssertEqual(state.mode, .files)
            XCTAssertEqual(defaults.string(forKey: modeKey), RightSidebarMode.files.rawValue)
        }
    }

    func testStoredCustomSidebarModePersistsWhenAvailable() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            let customSidebarsKey = BetaFeaturesCatalogSection().customSidebars.userDefaultsKey
            let previous = defaults.object(forKey: customSidebarsKey)
            defaults.set(true, forKey: customSidebarsKey)
            defer {
                if let previous {
                    defaults.set(previous, forKey: customSidebarsKey)
                } else {
                    defaults.removeObject(forKey: customSidebarsKey)
                }
            }
            defaults.set(RightSidebarMode.customSidebar.rawValue, forKey: modeKey)
            defaults.set("status-board", forKey: customSidebarNameKey)

            let state = FileExplorerState()

            XCTAssertEqual(state.mode, .customSidebar)
            XCTAssertEqual(defaults.string(forKey: modeKey), RightSidebarMode.customSidebar.rawValue)
        }
    }

    func testInjectedDefaultsOwnCustomSidebarAvailabilityAndPersistence() throws {
        let suiteName = "FileExplorerStateModePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let customSidebarsKey = BetaFeaturesCatalogSection().customSidebars.userDefaultsKey
        defaults.set(true, forKey: customSidebarsKey)
        defaults.set(RightSidebarMode.customSidebar.rawValue, forKey: modeKey)
        defaults.set("status-board", forKey: customSidebarNameKey)

        let state = FileExplorerState(defaults: defaults)

        XCTAssertEqual(state.mode, .customSidebar)
        XCTAssertTrue(RightSidebarMode.availableModes(defaults: defaults).contains(.customSidebar))
        state.selectCustomSidebar(name: "next-board")
        state.mode = .customSidebar
        XCTAssertEqual(state.customSidebarName, "next-board")
        XCTAssertEqual(defaults.string(forKey: customSidebarNameKey), "next-board")
        XCTAssertEqual(defaults.string(forKey: modeKey), RightSidebarMode.customSidebar.rawValue)
    // MARK: - sidebar.filesPanelPlacement = leading

    func testLeadingPlacementDropsFilesFromTheModeBar() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(FilesPanelPlacement.leading.rawValue, forKey: filesPanelPlacementKey)

            XCTAssertFalse(RightSidebarMode.visibleModes(defaults: defaults).contains(.files))
            XCTAssertTrue(
                RightSidebarMode.files.isAvailable(defaults: defaults),
                "Files stays a reachable mode (CLI, shortcut, palette); it is only not a tab"
            )

            defaults.set(FilesPanelPlacement.rightSidebar.rawValue, forKey: filesPanelPlacementKey)
            XCTAssertEqual(RightSidebarMode.visibleModes(defaults: defaults).first, .files)
        }
    }

    func testLeadingPlacementStoredFilesModeFallsBackToTheFirstVisibleTab() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(FilesPanelPlacement.leading.rawValue, forKey: filesPanelPlacementKey)
            defaults.set(RightSidebarMode.files.rawValue, forKey: modeKey)

            let state = FileExplorerState()

            let expected = RightSidebarMode.visibleModes(defaults: defaults).first
            XCTAssertNotEqual(state.mode, .files)
            XCTAssertEqual(state.mode, expected)
            XCTAssertEqual(defaults.string(forKey: modeKey), expected?.rawValue)
        }
    }

    func testLeadingPlacementModeSetterNeverLandsOnFiles() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(FilesPanelPlacement.leading.rawValue, forKey: filesPanelPlacementKey)
            let state = FileExplorerState()
            state.mode = .changes
            XCTAssertEqual(state.mode, .changes)

            state.mode = .files
            XCTAssertNotEqual(state.mode, .files, "the right sidebar has no Files tab to show")
            XCTAssertEqual(state.mode, RightSidebarMode.visibleModes(defaults: defaults).first)
        }
    }

    func testShowFilesRevealsTheLeadingPanelWithoutTouchingTheRightSidebar() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(FilesPanelPlacement.leading.rawValue, forKey: filesPanelPlacementKey)
            defaults.set(false, forKey: filesPanelVisibleKey)
            let state = FileExplorerState()
            state.setVisible(false)
            state.mode = .changes
            XCTAssertFalse(state.filesPanelVisible)
            XCTAssertFalse(state.filesAreShown())

            state.showFiles()

            XCTAssertTrue(state.filesPanelVisible)
            XCTAssertTrue(state.filesAreShown())
            XCTAssertTrue(defaults.bool(forKey: filesPanelVisibleKey), "the panel's visibility persists")
            XCTAssertFalse(state.isVisible, "the right sidebar stays hidden")
            XCTAssertEqual(state.mode, .changes, "the right sidebar keeps its tab")

            state.toggleFiles()
            XCTAssertFalse(state.filesPanelVisible)
            XCTAssertFalse(state.isVisible)

            state.toggleFiles()
            XCTAssertTrue(state.filesPanelVisible)
        }
    }

    func testShowFilesOpensTheRightSidebarOnFilesWhenTheTreeIsATab() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(FilesPanelPlacement.rightSidebar.rawValue, forKey: filesPanelPlacementKey)
            defaults.set(false, forKey: filesPanelVisibleKey)
            let state = FileExplorerState()
            state.setVisible(false)
            state.mode = .changes

            state.showFiles()

            XCTAssertTrue(state.isVisible)
            XCTAssertEqual(state.mode, .files)
            XCTAssertTrue(state.filesAreShown())
            XCTAssertFalse(state.filesPanelVisible, "the leading panel's flag is untouched")

            state.toggleFiles()
            XCTAssertFalse(state.isVisible, "hiding Files hides the sidebar showing it")
            XCTAssertEqual(state.mode, .files)

            state.setVisible(true)
            state.mode = .changes
            state.hideFiles()
            XCTAssertTrue(state.isVisible, "a sidebar on another tab is not showing Files, so it stays")
        }
    }

    // MARK: - sidebar.filesPanelPlacement = stacked

    func testStackedPlacementDropsFilesFromTheModeBarButKeepsCtrl1OnFiles() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(FilesPanelPlacement.stacked.rawValue, forKey: filesPanelPlacementKey)

            XCTAssertFalse(RightSidebarMode.visibleModes(defaults: defaults).contains(.files))
            XCTAssertFalse(
                RightSidebarMode.visibleModes(defaults: defaults, filesPanelPlacement: .stacked).contains(.files)
            )
            XCTAssertTrue(
                RightSidebarMode.files.isAvailable(defaults: defaults),
                "Files stays a reachable mode (CLI, shortcut, palette); it is only not a tab"
            )
            XCTAssertEqual(
                RightSidebarMode.positionalShortcutModes(defaults: defaults).first,
                .files,
                "Ctrl+1 stays Files; the mode bar's digits start at 2"
            )
            XCTAssertEqual(RightSidebarMode.positionalDigit(for: .files, defaults: defaults), 1)
            XCTAssertEqual(
                RightSidebarMode.positionalShortcutModes(defaults: defaults).dropFirst().map { $0 },
                RightSidebarMode.visibleModes(defaults: defaults)
            )
        }
    }

    func testStackedPlacementModeSetterNeverLandsOnFiles() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(FilesPanelPlacement.stacked.rawValue, forKey: filesPanelPlacementKey)
            defaults.set(RightSidebarMode.files.rawValue, forKey: modeKey)

            let state = FileExplorerState()
            let expected = RightSidebarMode.visibleModes(defaults: defaults).first
            XCTAssertNotEqual(state.mode, .files, "a stored Files mode falls back to the first visible tab")
            XCTAssertEqual(state.mode, expected)

            state.mode = .changes
            XCTAssertEqual(state.mode, .changes)
            state.mode = .files
            XCTAssertNotEqual(state.mode, .files, "the right sidebar has no Files tab to show")
            XCTAssertEqual(state.mode, expected)
        }
    }

    func testShowFilesRevealsTheStackedRegionAndTheSidebarThatHostsIt() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(FilesPanelPlacement.stacked.rawValue, forKey: filesPanelPlacementKey)
            defaults.set(false, forKey: filesPanelVisibleKey)
            let state = FileExplorerState()
            state.setVisible(false)
            state.mode = .changes
            let sidebar = SidebarState(isVisible: false)
            var revealCount = 0
            sidebar.installVisibilityWillChangeHandler(ownerId: UUID()) { isVisible in
                if isVisible { revealCount += 1 }
            }
            state.stackedSidebarState = sidebar
            XCTAssertFalse(state.filesAreShown())

            state.showFiles()

            XCTAssertTrue(state.filesPanelVisible)
            XCTAssertTrue(sidebar.isVisible, "showing Files shows the hidden workspace sidebar that hosts the tree")
            XCTAssertEqual(revealCount, 1)
            XCTAssertTrue(state.filesAreShown())
            XCTAssertTrue(defaults.bool(forKey: filesPanelVisibleKey), "the region's visibility persists")
            XCTAssertFalse(state.isVisible, "the right sidebar stays hidden")
            XCTAssertEqual(state.mode, .changes, "the right sidebar keeps its tab")

            // Closing the region leaves the workspace sidebar alone.
            state.hideFiles()
            XCTAssertFalse(state.filesPanelVisible)
            XCTAssertTrue(sidebar.isVisible)
            XCTAssertFalse(state.filesAreShown())

            // Toggling from closed re-opens it; a shown sidebar is left as is.
            state.toggleFiles()
            XCTAssertTrue(state.filesPanelVisible)
            XCTAssertTrue(state.filesAreShown())
            XCTAssertEqual(revealCount, 1, "a visible sidebar is not re-revealed")

            // With the sidebar hidden the tree is off screen even though the
            // region is open, so a toggle shows rather than hides.
            sidebar.setVisible(false)
            XCTAssertFalse(state.filesAreShown(), "a hidden sidebar hides the stacked tree with it")
            state.toggleFiles()
            XCTAssertTrue(state.filesPanelVisible)
            XCTAssertTrue(sidebar.isVisible)
            XCTAssertTrue(state.filesAreShown())
            XCTAssertEqual(revealCount, 2)

            // Another window's sidebar cannot detach this one; the host itself can.
            state.detachStackedSidebarState(SidebarState(isVisible: true))
            sidebar.setVisible(false)
            XCTAssertFalse(state.filesAreShown())
            state.detachStackedSidebarState(sidebar)
            XCTAssertTrue(state.filesAreShown(), "without a host the sidebar is assumed visible")
        }
    }

    func testStackedSidebarStateIsHeldWeakly() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set(FilesPanelPlacement.stacked.rawValue, forKey: filesPanelPlacementKey)
            defaults.set(true, forKey: filesPanelVisibleKey)
            let state = FileExplorerState()
            do {
                let sidebar = SidebarState(isVisible: false)
                state.stackedSidebarState = sidebar
                XCTAssertFalse(state.filesAreShown())
            }
            XCTAssertNil(state.stackedSidebarState, "the window owns its sidebar state; this reference must not keep it alive")
            XCTAssertTrue(state.filesAreShown(), "a released host falls back to assuming the sidebar visible")
        }
    }

    func testStackedHeightPersistsAndFallsBackToTheDefault() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: FileExplorerState.filesPanelStackedHeightKey)
            let fresh = FileExplorerState()
            XCTAssertEqual(fresh.filesPanelStackedHeight, FilesPanelStackedLayout.defaultHeight)

            fresh.filesPanelStackedHeight = 244
            XCTAssertEqual(defaults.double(forKey: FileExplorerState.filesPanelStackedHeightKey), 244, accuracy: 0.001)
            XCTAssertEqual(FileExplorerState().filesPanelStackedHeight, 244, accuracy: 0.001)

            defaults.set(-10.0, forKey: FileExplorerState.filesPanelStackedHeightKey)
            XCTAssertEqual(
                FileExplorerState().filesPanelStackedHeight,
                FilesPanelStackedLayout.defaultHeight,
                "a non-positive persisted height is discarded"
            )
        }
    }

    func testCLIArgumentNormalizerMapsVaultAndSessionsToSessions() {
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "files"), .files)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "find"), .find)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "vault"), .sessions)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "sessions"), .sessions)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "feed"), .feed)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "dock"), .dock)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: " Vault "), .sessions)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "custom-sidebar"), .customSidebar)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "custom"), .customSidebar)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "changes"), .changes)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "diff"), .changes)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "git"), .changes)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: " Changes "), .changes)
        XCTAssertNil(RightSidebarMode.from(cliArgument: "unknown"))
    }

    private func withSavedRightSidebarModeDefaults(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previousMode = defaults.object(forKey: modeKey)
        let previousCustomSidebarName = defaults.object(forKey: customSidebarNameKey)
        let previousFeedEnabled = defaults.object(forKey: feedEnabledKey)
        let previousLegacyDockBeta = defaults.object(forKey: legacyDockBetaKey)
        let previousFilesPanelPlacement = defaults.object(forKey: filesPanelPlacementKey)
        let previousFilesPanelVisible = defaults.object(forKey: filesPanelVisibleKey)
        let previousFilesPanelStackedHeight = defaults.object(forKey: FileExplorerState.filesPanelStackedHeightKey)
        let previousRightSidebarVisible = defaults.object(forKey: "fileExplorer.isVisible")
        defer {
            restore(previousMode, forKey: modeKey)
            restore(previousCustomSidebarName, forKey: customSidebarNameKey)
            restore(previousFeedEnabled, forKey: feedEnabledKey)
            restore(previousLegacyDockBeta, forKey: legacyDockBetaKey)
            restore(previousFilesPanelPlacement, forKey: filesPanelPlacementKey)
            restore(previousFilesPanelVisible, forKey: filesPanelVisibleKey)
            restore(previousFilesPanelStackedHeight, forKey: FileExplorerState.filesPanelStackedHeightKey)
            restore(previousRightSidebarVisible, forKey: "fileExplorer.isVisible")
        }
        // The placement is read through the catalog on every check, so start
        // each case from the catalog default unless the case sets it.
        defaults.removeObject(forKey: filesPanelPlacementKey)
        body()
    }

    private func restore(_ value: Any?, forKey key: String) {
        let defaults = UserDefaults.standard
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
