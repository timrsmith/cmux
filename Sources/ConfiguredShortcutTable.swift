import Foundation

/// Resolved shortcut bindings for the app-wide key-event handler, cached per
/// action and dropped whenever the shortcut-settings generation moves.
///
/// `AppDelegate.matchConfiguredShortcut(event:action:)` runs for dozens of
/// actions on every key event. Resolving one binding through
/// `KeyboardShortcutSettings.shortcut(for:)` reads the `cmux.json` store under
/// its lock, the `UserDefaults` override (with a JSON decode), and the
/// legacy-conflict resolver, so repeating that per action per keystroke sits
/// on the typing path. This table resolves each action once per generation of
/// ``SavingTextViewShortcutGeneration`` (the counter the file editor's
/// candidate cache already uses; it is bumped by
/// `KeyboardShortcutSettings.didChangeNotification` and
/// `UserDefaults.didChangeNotification`, which together cover every input of
/// `shortcut(for:)`) and forgets every entry when the generation changes, so
/// the table is refilled lazily from the actions the next events consult.
///
/// Only the resolved stroke is cached. The `when` clause depends on the
/// event's focus state and stays evaluated per event by the caller.
///
/// ```swift
/// private let configuredShortcutTable = ConfiguredShortcutTable()
///
/// func matchConfiguredShortcut(event: NSEvent, action: KeyboardShortcutSettings.Action) -> Bool {
///     if !shortcutWhenClauseAllows(action: action, event: event) { return false }
///     return matchConfiguredShortcut(event: event, shortcut: configuredShortcutTable.shortcut(for: action))
/// }
/// ```
@MainActor
final class ConfiguredShortcutTable {
    typealias ShortcutResolver = (KeyboardShortcutSettings.Action) -> StoredShortcut
    typealias GenerationProvider = () -> Int

    private let resolve: ShortcutResolver
    private let generation: GenerationProvider
    private var cachedGeneration: Int?
    private var shortcutsByAction: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]

    /// - Parameters:
    ///   - resolve: Produces the effective binding for an action. Defaults to
    ///     `KeyboardShortcutSettings.shortcut(for:)`; tests inject a counter.
    ///   - generation: The current shortcut-settings generation. Defaults to
    ///     the editor's shared counter so both caches invalidate together.
    init(
        resolve: @escaping ShortcutResolver = KeyboardShortcutSettings.shortcut(for:),
        generation: @escaping GenerationProvider = { SavingTextViewShortcutGeneration.shared.current }
    ) {
        self.resolve = resolve
        self.generation = generation
    }

    /// The effective binding for `action`, resolved at most once per
    /// generation. Returns `.unbound` for an action without a binding, exactly
    /// as `KeyboardShortcutSettings.shortcut(for:)` does.
    func shortcut(for action: KeyboardShortcutSettings.Action) -> StoredShortcut {
        let current = generation()
        if cachedGeneration != current {
            shortcutsByAction.removeAll(keepingCapacity: true)
            cachedGeneration = current
        }
        if let cached = shortcutsByAction[action] {
            return cached
        }
        let resolved = resolve(action)
        shortcutsByAction[action] = resolved
        return resolved
    }
}
