import CmuxCloud
import AppKit
import CmuxSettings
import Foundation

extension RightSidebarMode {
    static func from(cliArgument rawValue: String) -> RightSidebarMode? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "files":
            return .files
        case "find":
            return .find
        case "vault", "sessions":
            return .sessions
        case "feed":
            return .feed
        case "dock":
            return .dock
        case "cloud", "machines", "vms":
            return .machines
        case "devices", "device", "macs":
            return .machines
        case "changes", "diff", "git":
            return .changes
        case "custom", "custom-sidebar":
            return .customSidebar
        default:
            return nil
        }
    }

    static func availableModes(defaults: UserDefaults = .standard) -> [RightSidebarMode] {
        var modes = availableModes(
            feedEnabled: RightSidebarBetaFeatureSettings.isFeedEnabled(defaults: defaults),
            machinesEnabled: CloudMachinesFeature.offMainIsAvailable(),
            devicesEnabled: false
        )
        if CmuxExtensionSidebarSelection.customSidebarsEnabled(defaults: defaults),
           FileExplorerState.persistedCustomSidebarName(defaults: defaults) != nil {
            modes.append(.customSidebar)
        }
        return modes
    }

    static func availableModes(
        feedEnabled: Bool,
        machinesEnabled: Bool,
        devicesEnabled: Bool = false
    ) -> [RightSidebarMode] {
        allCases.filter {
            $0.isAvailable(
                feedEnabled: feedEnabled,
                machinesEnabled: machinesEnabled,
                devicesEnabled: devicesEnabled
            )
        }
    }

    func isAvailable(defaults: UserDefaults = .standard) -> Bool {
        if self == .customSidebar {
            return CmuxExtensionSidebarSelection.customSidebarsEnabled(defaults: defaults)
                && FileExplorerState.persistedCustomSidebarName(defaults: defaults) != nil
        }
        return isAvailable(
            feedEnabled: RightSidebarBetaFeatureSettings.isFeedEnabled(defaults: defaults),
            machinesEnabled: CloudMachinesFeature.offMainIsAvailable(),
            devicesEnabled: false
        )
    }

    /// The tabs the mode bar actually shows: feature-available modes in the
    /// user's configured order, minus the ones the user hid. With
    /// `sidebar.filesPanelPlacement` set to `leading` the file tree is its own
    /// panel, so `.files` is never a tab (`isAvailable` still reports it, since
    /// the mode can be shown; `FileExplorerState.showFiles` routes it to the
    /// panel). See `positionalShortcutModes` for the `ctrl+1…9` digits.
    nonisolated static func visibleModes(defaults: UserDefaults = .standard) -> [RightSidebarMode] {
        visibleModes(
            defaults: defaults,
            filesPanelPlacement: FileExplorerState.filesPanelPlacement(defaults: defaults)
        )
    }

    nonisolated static func visibleModes(
        defaults: UserDefaults,
        filesPanelPlacement: FilesPanelPlacement
    ) -> [RightSidebarMode] {
        let hidden = RightSidebarTabPreferences.hiddenModes(defaults: defaults)
        let isTab: (RightSidebarMode) -> Bool = { mode in
            mode.isAvailable(defaults: defaults) && (mode != .files || filesPanelPlacement == .rightSidebar)
        }
        let visible = RightSidebarTabPreferences.orderedModes(defaults: defaults)
            .filter { isTab($0) && !hidden.contains($0) }
        // A hidden set written directly to defaults can hide everything; the
        // sidebar still needs tabs, so fall back to every available tab.
        return visible.isEmpty ? availableModes(defaults: defaults).filter(isTab) : visible
    }

    /// The modes that own the positional `ctrl+1…9` digit-shortcut defaults,
    /// so the Nth entry always answers ctrl+N unless the user rebound it. This
    /// is the mode bar's visible tabs, except that a leading files panel keeps
    /// `ctrl+1` as the first tool: it is the same "show Files" action as
    /// before, just docked elsewhere, and the mode bar's digits start at 2.
    nonisolated static func positionalShortcutModes(defaults: UserDefaults = .standard) -> [RightSidebarMode] {
        let placement = FileExplorerState.filesPanelPlacement(defaults: defaults)
        let tabs = visibleModes(defaults: defaults, filesPanelPlacement: placement)
        return placement == .leading ? [.files] + tabs : tabs
    }

    /// 1-based `ctrl+digit` position of `mode` in `positionalShortcutModes`,
    /// or nil when the mode is hidden, unavailable, or past position 9. Single
    /// source for the app's positional shortcut defaults and the CmuxSettings
    /// default-stroke override.
    nonisolated static func positionalDigit(
        for mode: RightSidebarMode,
        defaults: UserDefaults = .standard
    ) -> Int? {
        let modes = positionalShortcutModes(defaults: defaults)
        guard let index = modes.firstIndex(of: mode), index < 9 else { return nil }
        return index + 1
    }

    func isAvailable(
        feedEnabled: Bool,
        machinesEnabled: Bool,
        devicesEnabled: Bool = false
    ) -> Bool {
        switch self {
        case .files, .find, .sessions, .changes:
            return true
        case .feed:
            return feedEnabled
        case .dock:
            return true
        case .machines:
            return machinesEnabled
        case .customSidebar:
            // Available once the custom-sidebars beta is on AND a right-side
            // sidebar has been picked (right_sidebar set custom <name>); the
            // mode bar then grows a Custom button.
            return CmuxExtensionSidebarSelection.customSidebarsEnabled
                && FileExplorerState.persistedCustomSidebarName() != nil
        }
    }
}

enum RightSidebarKeyboardNavigation {
    enum DisclosureAction {
        case collapse
        case expand
    }

    static func moveDelta(for event: NSEvent) -> Int? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommandOrOption = !flags.intersection([.command, .option]).isEmpty
        if flags.contains(.control), !hasCommandOrOption {
            switch event.keyCode {
            case 45: return 1   // Ctrl+N
            case 35: return -1  // Ctrl+P
            default: break
            }
        }

        guard flags.intersection([.command, .control, .option]).isEmpty else {
            return nil
        }
        switch event.keyCode {
        case 38, 125: return 1   // J or Down
        case 40, 126: return -1  // K or Up
        default: return nil
        }
    }

    static func disclosureAction(for event: NSEvent) -> DisclosureAction? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .control, .option]).isEmpty else {
            return nil
        }
        switch event.keyCode {
        case 4: return .collapse  // H
        case 37: return .expand   // L
        case 123: return .collapse  // Left
        case 124: return .expand   // Right
        default: return nil
        }
    }

    static func isPlainSlash(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        return event.keyCode == 44
    }

    static func isPlainPrintableText(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        guard let text = event.charactersIgnoringModifiers, !text.isEmpty else {
            return false
        }
        return text.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }
}
