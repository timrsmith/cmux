import CmuxSettings
import Foundation

enum FileExplorerDoubleClickActionSettings {
    /// The catalog key behind every read and write of the choice.
    static let catalogKey = FileExplorerCatalogSection().doubleClickAction
    static let key = catalogKey.userDefaultsKey
    static let didChangeNotification = Notification.Name("cmux.fileExplorerDoubleClickActionDidChange")
    static let defaultValue: FileExplorerDoubleClickAction = catalogKey.defaultValue

    /// Parse a raw config string into an action. Legacy values fold into the
    /// choice that replaced them (`FileExplorerDoubleClickAction.legacyRawValues`);
    /// `nil` or unrecognized values fall back to ``defaultValue`` (`.preview`).
    /// The stored choice is read through the catalog key (``resolvedAction(defaults:)``);
    /// this remains for the parse-contract tests.
    static func action(forRawValue raw: String?) -> FileExplorerDoubleClickAction {
        FileExplorerDoubleClickAction.decodeFromJSON(raw) ?? defaultValue
    }

    /// The stored choice, decoded by the catalog key; an unset or undecodable
    /// value is ``defaultValue``. Every entrypoint that opens a file from the
    /// tree, the right sidebar, or a diff viewer resolves through here
    /// (`Workspace.openFile(_:inPane:activation:)`) so the choice is honored
    /// identically.
    static func resolvedAction(defaults: UserDefaults = .standard) -> FileExplorerDoubleClickAction {
        catalogKey.value(in: defaults)
    }

    static func setAction(
        _ action: FileExplorerDoubleClickAction,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        catalogKey.set(action, in: defaults)
        notifyDidChange(notificationCenter: notificationCenter)
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }
}
