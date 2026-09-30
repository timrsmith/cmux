import CmuxSettings
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior of the customizable right-sidebar tabs: user-defined order and
/// visibility, and the positional `ctrl+digit` shortcut defaults that follow
/// the visible order (the Nth visible tab answers ctrl+N).
@MainActor
final class RightSidebarTabCustomizationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var savedCloudRemoteOverride: Bool?

    override func setUp() {
        super.setUp()
        suiteName = "RightSidebarTabCustomizationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        let flag = CmuxFeatureFlags.cloudMachinesFlag
        savedCloudRemoteOverride = CmuxFeatureFlags.shared.overrideValue(for: flag)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        CmuxFeatureFlags.shared.setOverride(savedCloudRemoteOverride, for: CmuxFeatureFlags.cloudMachinesFlag)
        savedCloudRemoteOverride = nil
        defaults = nil
        super.tearDown()
    }

    private func enableAllModeGates() {
        defaults.set(true, forKey: RightSidebarBetaFeatureSettings.feedEnabledKey)
        defaults.set(true, forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)
    }

    private func enableMachinesGate() {
        defaults.set(true, forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)
    }

    private func dockFilesPanelLeading() {
        defaults.set(
            FilesPanelPlacement.leading.rawValue,
            forKey: SidebarCatalogSection().filesPanelPlacement.userDefaultsKey
        )
    }

    // MARK: - Ordering and visibility

    func testDefaultOrderIsCanonical() {
        XCTAssertEqual(
            RightSidebarTabPreferences.orderedModes(defaults: defaults),
            [.files, .find, .sessions, .feed, .dock, .machines, .changes]
        )
    }

    func testStoredOrderIgnoresUnknownEntriesAndAppendsMissingModes() {
        defaults.set(["machines", "bogus", "files", "custom-sidebar"], forKey: RightSidebarTabPreferences.orderKey)
        XCTAssertEqual(
            RightSidebarTabPreferences.orderedModes(defaults: defaults),
            [.machines, .files, .find, .sessions, .feed, .dock, .changes]
        )
    }

    func testVisibleModesDropUserHiddenTabs() {
        CmuxFeatureFlags.shared.setOverride(true, for: CmuxFeatureFlags.cloudMachinesFlag)
        enableAllModeGates()
        XCTAssertTrue(RightSidebarTabPreferences.setHidden(true, mode: .find, defaults: defaults))
        XCTAssertEqual(
            RightSidebarMode.visibleModes(defaults: defaults),
            [.files, .sessions, .feed, .dock, .machines, .changes]
        )
    }

    func testHidingLastVisibleTabIsRefused() {
        // Hide every tab except Sessions through the regular tab-visibility
        // control; the Dock is no longer beta-gated.
        XCTAssertTrue(RightSidebarTabPreferences.setHidden(true, mode: .files, defaults: defaults))
        XCTAssertTrue(RightSidebarTabPreferences.setHidden(true, mode: .find, defaults: defaults))
        XCTAssertTrue(RightSidebarTabPreferences.setHidden(true, mode: .machines, defaults: defaults))
        XCTAssertTrue(RightSidebarTabPreferences.setHidden(true, mode: .dock, defaults: defaults))
        XCTAssertTrue(RightSidebarTabPreferences.setHidden(true, mode: .changes, defaults: defaults))
        XCTAssertFalse(
            RightSidebarTabPreferences.setHidden(true, mode: .sessions, defaults: defaults),
            "the last visible tab must stay visible"
        )
        XCTAssertEqual(RightSidebarMode.visibleModes(defaults: defaults), [.sessions])
    }

    func testMoveReordersAndClampsAtEdges() {
        RightSidebarTabPreferences.move(.machines, offset: -5, defaults: defaults)
        XCTAssertEqual(
            RightSidebarTabPreferences.orderedModes(defaults: defaults),
            [.machines, .files, .find, .sessions, .feed, .dock, .changes]
        )
        RightSidebarTabPreferences.move(.machines, offset: -1, defaults: defaults)
        XCTAssertEqual(
            RightSidebarTabPreferences.orderedModes(defaults: defaults).first,
            .machines,
            "moving past the front clamps"
        )
    }

    func testSetDisplayedOrderPermutesOnlyTheDisplayedSlots() {
        // Hide Feed; Dock keeps its slot in the full order. Dragging Cloud
        // before Files must not move Feed or Dock.
        enableAllModeGates()
        RightSidebarTabPreferences.setHidden(true, mode: .feed, defaults: defaults)
        RightSidebarTabPreferences.setDisplayedOrder(
            [.machines, .files, .find, .sessions, .dock],
            defaults: defaults
        )
        XCTAssertEqual(
            RightSidebarTabPreferences.orderedModes(defaults: defaults),
            [.machines, .files, .find, .feed, .sessions, .dock, .changes],
            "hidden Feed keeps its 4th slot while the displayed tabs permute around it"
        )
    }

    func testModeBarReorderPolicyMovesDraggedPillOverTarget() {
        let displayed: [RightSidebarMode] = [.files, .find, .sessions, .machines]
        XCTAssertEqual(
            RightSidebarModeBarReorderPolicy.displayedOrder(moving: .machines, over: .files, in: displayed),
            [.machines, .files, .find, .sessions]
        )
        XCTAssertEqual(
            RightSidebarModeBarReorderPolicy.displayedOrder(moving: .files, over: .sessions, in: displayed),
            [.find, .sessions, .files, .machines]
        )
        XCTAssertNil(
            RightSidebarModeBarReorderPolicy.displayedOrder(moving: .files, over: .files, in: displayed)
        )
        XCTAssertNil(
            RightSidebarModeBarReorderPolicy.displayedOrder(moving: .feed, over: .files, in: displayed),
            "a mode absent from the bar cannot reorder it"
        )
    }

    func testResetRestoresCanonicalOrderAndVisibility() {
        RightSidebarTabPreferences.move(.machines, offset: -5, defaults: defaults)
        RightSidebarTabPreferences.setHidden(true, mode: .find, defaults: defaults)
        RightSidebarTabPreferences.resetToDefaults(defaults: defaults)
        XCTAssertEqual(
            RightSidebarTabPreferences.orderedModes(defaults: defaults),
            [.files, .find, .sessions, .feed, .dock, .machines, .changes]
        )
        XCTAssertTrue(RightSidebarTabPreferences.hiddenModes(defaults: defaults).isEmpty)
    }

    // MARK: - Positional shortcut defaults

    /// With Feed and Dock hidden through the regular tab-visibility controls,
    /// Cloud is the 4th visible tab, so ctrl+4 must focus it.
    func testCloudDefaultsToControlFourWhenFeedAndDockAreHidden() {
        CmuxFeatureFlags.shared.setOverride(true, for: CmuxFeatureFlags.cloudMachinesFlag)
        enableMachinesGate()
        XCTAssertTrue(RightSidebarTabPreferences.setHidden(true, mode: .feed, defaults: defaults))
        XCTAssertTrue(RightSidebarTabPreferences.setHidden(true, mode: .dock, defaults: defaults))
        XCTAssertEqual(
            RightSidebarMode.visibleModes(defaults: defaults),
            [.files, .find, .sessions, .machines, .changes]
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.rightSidebarPositionalDefaultShortcut(for: .machines, defaults: defaults),
            StoredShortcut(key: "4", command: false, shift: false, option: false, control: true)
        )
    }

    func testAllTabsVisibleKeepsHistoricDigits() {
        CmuxFeatureFlags.shared.setOverride(true, for: CmuxFeatureFlags.cloudMachinesFlag)
        enableAllModeGates()
        let expected: [(RightSidebarMode, String)] = [
            (.files, "1"), (.find, "2"), (.sessions, "3"), (.feed, "4"), (.dock, "5"), (.machines, "6"),
            (.changes, "7"),
        ]
        for (mode, digit) in expected {
            XCTAssertEqual(
                KeyboardShortcutSettings.rightSidebarPositionalDefaultShortcut(for: mode, defaults: defaults),
                StoredShortcut(key: digit, command: false, shift: false, option: false, control: true),
                "\(mode) should default to ctrl+\(digit)"
            )
        }
    }

    func testHiddenTabDefaultsToUnboundAndLaterDigitsShift() {
        CmuxFeatureFlags.shared.setOverride(true, for: CmuxFeatureFlags.cloudMachinesFlag)
        enableAllModeGates()
        RightSidebarTabPreferences.setHidden(true, mode: .find, defaults: defaults)
        XCTAssertEqual(
            KeyboardShortcutSettings.rightSidebarPositionalDefaultShortcut(for: .find, defaults: defaults),
            .unbound
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.rightSidebarPositionalDefaultShortcut(for: .sessions, defaults: defaults),
            StoredShortcut(key: "2", command: false, shift: false, option: false, control: true)
        )
    }

    func testReorderMovesDigitsWithTheTabs() {
        CmuxFeatureFlags.shared.setOverride(true, for: CmuxFeatureFlags.cloudMachinesFlag)
        enableAllModeGates()
        RightSidebarTabPreferences.move(.machines, offset: -5, defaults: defaults)
        XCTAssertEqual(
            KeyboardShortcutSettings.rightSidebarPositionalDefaultShortcut(for: .machines, defaults: defaults),
            StoredShortcut(key: "1", command: false, shift: false, option: false, control: true)
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.rightSidebarPositionalDefaultShortcut(for: .files, defaults: defaults),
            StoredShortcut(key: "2", command: false, shift: false, option: false, control: true)
        )
    }

    func testPositionalDigitStopsAtNine() {
        enableAllModeGates()
        for (index, mode) in RightSidebarMode.visibleModes(defaults: defaults).enumerated() {
            XCTAssertEqual(
                RightSidebarMode.positionalDigit(for: mode, defaults: defaults),
                index < 9 ? index + 1 : nil
            )
        }
    }

    // MARK: - Leading files panel

    func testLeadingFilesPanelRemovesTheFilesTabFromTheBar() {
        CmuxFeatureFlags.shared.setOverride(true, for: CmuxFeatureFlags.cloudMachinesFlag)
        enableAllModeGates()
        dockFilesPanelLeading()
        XCTAssertEqual(
            RightSidebarMode.visibleModes(defaults: defaults),
            [.find, .sessions, .feed, .dock, .machines, .changes]
        )
        XCTAssertEqual(
            RightSidebarMode.visibleModes(defaults: defaults, filesPanelPlacement: .rightSidebar),
            [.files, .find, .sessions, .feed, .dock, .machines, .changes],
            "the explicit placement overload is what the mode bar reads"
        )
    }

    func testLeadingFilesPanelKeepsControlOneAndShiftsTheTabsToTwo() {
        CmuxFeatureFlags.shared.setOverride(true, for: CmuxFeatureFlags.cloudMachinesFlag)
        enableAllModeGates()
        dockFilesPanelLeading()
        XCTAssertEqual(
            RightSidebarMode.positionalShortcutModes(defaults: defaults),
            [.files, .find, .sessions, .feed, .dock, .machines, .changes]
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.rightSidebarPositionalDefaultShortcut(for: .files, defaults: defaults),
            StoredShortcut(key: "1", command: false, shift: false, option: false, control: true),
            "the docked file tree is still the first tool: Ctrl+1 shows it"
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.rightSidebarPositionalDefaultShortcut(for: .find, defaults: defaults),
            StoredShortcut(key: "2", command: false, shift: false, option: false, control: true)
        )
    }

    // MARK: - Stacked files panel

    func testStackedFilesPanelRemovesTheFilesTabAndKeepsControlOne() {
        CmuxFeatureFlags.shared.setOverride(true, for: CmuxFeatureFlags.cloudMachinesFlag)
        enableAllModeGates()
        defaults.set(
            FilesPanelPlacement.stacked.rawValue,
            forKey: SidebarCatalogSection().filesPanelPlacement.userDefaultsKey
        )
        XCTAssertEqual(
            RightSidebarMode.visibleModes(defaults: defaults),
            [.find, .sessions, .feed, .dock, .machines, .changes],
            "the tree above the workspace list is not a right-sidebar tab"
        )
        XCTAssertEqual(
            RightSidebarMode.positionalShortcutModes(defaults: defaults),
            [.files, .find, .sessions, .feed, .dock, .machines, .changes]
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.rightSidebarPositionalDefaultShortcut(for: .files, defaults: defaults),
            StoredShortcut(key: "1", command: false, shift: false, option: false, control: true),
            "the stacked file tree is still the first tool: Ctrl+1 shows it"
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.rightSidebarPositionalDefaultShortcut(for: .find, defaults: defaults),
            StoredShortcut(key: "2", command: false, shift: false, option: false, control: true)
        )
    }

    func testLeadingFilesPanelIgnoresAHiddenFilesTabPreference() {
        enableAllModeGates()
        RightSidebarTabPreferences.setHidden(true, mode: .files, defaults: defaults)
        dockFilesPanelLeading()
        XCTAssertEqual(
            RightSidebarMode.positionalShortcutModes(defaults: defaults).first,
            .files,
            "hiding the Files tab is a mode-bar preference; the docked panel is not a tab"
        )
        XCTAssertFalse(RightSidebarMode.visibleModes(defaults: defaults).contains(.files))
    }

    func testHidingEveryOtherTabStillLeavesTheBarATabWhenFilesIsDocked() {
        // With Files docked leading the fallback for an over-hidden set must
        // not resurrect Files as a tab.
        dockFilesPanelLeading()
        defaults.set(
            [RightSidebarMode.find, .sessions, .machines, .changes, .feed, .dock].map(\.rawValue),
            forKey: RightSidebarTabPreferences.hiddenKey
        )
        let visible = RightSidebarMode.visibleModes(defaults: defaults)
        XCTAssertFalse(visible.isEmpty)
        XCTAssertFalse(visible.contains(.files))
    }

    func testMutationsPostShortcutSettingsDidChange() {
        enableAllModeGates()
        let expectation = expectation(
            forNotification: KeyboardShortcutSettings.didChangeNotification,
            object: nil
        )
        RightSidebarTabPreferences.setHidden(true, mode: .feed, defaults: defaults)
        wait(for: [expectation], timeout: 1)
    }
}
