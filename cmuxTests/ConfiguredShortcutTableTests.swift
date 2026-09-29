import AppKit
import Carbon
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `ConfiguredShortcutTable` resolves each action once per shortcut-settings
/// generation and forgets everything when the generation moves, so the
/// app-wide key handler stops re-reading settings on every keystroke.
@MainActor
@Suite(.serialized)
struct ConfiguredShortcutTableTests {
    @Test("repeated lookups within one generation resolve each action once")
    func repeatedLookupsResolveOnce() {
        var resolved: [KeyboardShortcutSettings.Action] = []
        var generation = 1
        let bound = StoredShortcut(key: "g", command: true, shift: false, option: false, control: false)
        let table = ConfiguredShortcutTable(
            resolve: { action in
                resolved.append(action)
                return action == .findNext ? bound : .unbound
            },
            generation: { generation }
        )

        #expect(table.shortcut(for: .findNext) == bound)
        #expect(table.shortcut(for: .findNext) == bound)
        #expect(table.shortcut(for: .findPrevious) == .unbound)
        #expect(table.shortcut(for: .findNext) == bound)
        #expect(table.shortcut(for: .findPrevious) == .unbound)
        #expect(resolved == [.findNext, .findPrevious], "each action is resolved once per generation")

        generation += 1
        #expect(table.shortcut(for: .findNext) == bound)
        #expect(resolved == [.findNext, .findPrevious, .findNext], "a new generation re-resolves on demand")
        #expect(table.shortcut(for: .findNext) == bound)
        #expect(resolved.count == 3)
    }

    /// The whole path: `AppDelegate.matchConfiguredShortcut` consults the
    /// table, so a repeated key event never reaches
    /// `KeyboardShortcutSettings.shortcut(for:)` after warm-up, and a
    /// settings change (which bumps the shared generation) rebuilds.
    @Test("a repeated key event does not re-resolve shortcuts, a settings change does")
    func appDelegateMatcherReusesResolvedShortcuts() throws {
        #if DEBUG
        let appDelegate = try #require(AppDelegate.shared)
        appDelegate.debugResetShortcutRoutingStateForTesting()
        defer {
            KeyboardShortcutSettings.shortcutLookupObserver = nil
            appDelegate.debugResetShortcutRoutingStateForTesting()
        }
        try withDefaultShortcutSettings(prefix: "cmux-configured-shortcut-table") {
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: [.command],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: 0,
                    context: nil,
                    characters: ",",
                    charactersIgnoringModifiers: ",",
                    isARepeat: false,
                    keyCode: UInt16(kVK_ANSI_Comma)
                )
            )
            try #require(
                appDelegate.shortcutWhenClauseAllows(action: .openSettings, event: event),
                "the app-wide Settings shortcut must not be gated by focus for this event"
            )

            var lookups = 0
            KeyboardShortcutSettings.shortcutLookupObserver = { action in
                if action == .openSettings { lookups += 1 }
            }

            #expect(appDelegate.matchConfiguredShortcut(event: event, action: .openSettings))
            #expect(lookups > 0, "the first event resolves the binding")
            let warm = lookups

            #expect(appDelegate.matchConfiguredShortcut(event: event, action: .openSettings))
            #expect(appDelegate.matchConfiguredShortcut(event: event, action: .openSettings))
            #expect(lookups == warm, "repeated events reuse the resolved binding")

            KeyboardShortcutSettings.setShortcut(.unbound, for: .openSettings)
            #expect(!appDelegate.matchConfiguredShortcut(event: event, action: .openSettings))
            #expect(lookups > warm, "a settings change rebuilds the table")
            let rebuilt = lookups
            #expect(!appDelegate.matchConfiguredShortcut(event: event, action: .openSettings))
            #expect(lookups == rebuilt)

            KeyboardShortcutSettings.resetShortcut(for: .openSettings)
            #expect(appDelegate.matchConfiguredShortcut(event: event, action: .openSettings))
            #expect(lookups > rebuilt, "restoring the default rebuilds again")
        }
        #else
        Issue.record("shortcutLookupObserver is only available in DEBUG")
        #endif
    }
}
