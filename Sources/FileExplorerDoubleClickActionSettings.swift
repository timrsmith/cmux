import CmuxSettings
import Foundation

/// The concrete open behavior for a file activation. It mirrors
/// ``FileExplorerDoubleClickAction`` case for case and stays a separate type so
/// `Workspace.openFile(_:inPane:activation:)`, the single routing every
/// sidebar-style file open shares, can be handed a behavior directly (a caller
/// that shows a downloaded copy passes `.preview`) without reading the setting.
enum FileExplorerFileActivation: Equatable, Sendable {
    /// The built-in cmux editor surface.
    case preview
    /// A terminal surface running the user's terminal editor on the file.
    case terminalEditor
}

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
    /// value is ``defaultValue``.
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

    /// The concrete behavior for a FILE activation under `action`. Directories
    /// are handled by the caller and never reach this function. Neither choice
    /// falls back: the terminal editor's command resolver always yields an
    /// editor (`vi` at worst).
    static func fileActivation(action: FileExplorerDoubleClickAction) -> FileExplorerFileActivation {
        switch action {
        case .preview:
            return .preview
        case .terminalEditor:
            return .terminalEditor
        }
    }

    /// The activation for a file open right now, from the stored choice. Every
    /// entrypoint that opens a file from the tree, the right sidebar, or a diff
    /// viewer resolves through here so the choice is honored identically.
    static func resolvedFileActivation(defaults: UserDefaults = .standard) -> FileExplorerFileActivation {
        fileActivation(action: resolvedAction(defaults: defaults))
    }
}
