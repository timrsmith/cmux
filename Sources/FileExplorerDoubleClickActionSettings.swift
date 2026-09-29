import CmuxSettings
import Foundation

/// The concrete open behavior for a file activation, after resolving the
/// configured action and any fallbacks. Computed by
/// ``FileExplorerDoubleClickActionSettings/fileActivation(action:hasPreferredEditorCommand:)``
/// and consumed by `Workspace.openFile(_:inPane:activation:)`, the single
/// routing every sidebar-style file open shares.
enum FileExplorerFileActivation: Equatable, Sendable {
    /// The built-in cmux editor surface.
    case preview
    /// A terminal surface running the user's terminal editor on the file.
    case terminalEditor
    /// The macOS default application for the file type.
    case defaultEditor
    /// The `app.preferredEditor` command.
    case preferredEditor
}

enum FileExplorerDoubleClickActionSettings {
    /// The catalog key behind every read and write of the choice.
    static let catalogKey = FileExplorerCatalogSection().doubleClickAction
    static let key = catalogKey.userDefaultsKey
    static let didChangeNotification = Notification.Name("cmux.fileExplorerDoubleClickActionDidChange")
    static let defaultValue: FileExplorerDoubleClickAction = catalogKey.defaultValue

    /// Parse a raw config string into an action, falling back to
    /// ``defaultValue`` (`.preview`) for `nil` or unrecognized values. The
    /// stored choice is read through the catalog key (``resolvedAction(defaults:)``);
    /// this remains for the parse-contract tests.
    static func action(forRawValue raw: String?) -> FileExplorerDoubleClickAction {
        raw.flatMap(FileExplorerDoubleClickAction.init(rawValue:)) ?? defaultValue
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

    /// Resolve the concrete behavior for a FILE activation given the chosen
    /// action and whether a preferred-editor command is configured. Directories
    /// are handled by the caller and never reach this function.
    ///
    /// The `preferredEditor` action falls back to `defaultEditor` when no
    /// preferred-editor command is set, mirroring the terminal Cmd-click path's
    /// behavior of opening with the system default when `app.preferredEditor`
    /// is empty. `terminalEditor` never falls back: its command resolver
    /// always yields an editor (`vi` at worst).
    static func fileActivation(
        action: FileExplorerDoubleClickAction,
        hasPreferredEditorCommand: Bool
    ) -> FileExplorerFileActivation {
        switch action {
        case .preview:
            return .preview
        case .terminalEditor:
            return .terminalEditor
        case .defaultEditor:
            return .defaultEditor
        case .preferredEditor:
            return hasPreferredEditorCommand ? .preferredEditor : .defaultEditor
        }
    }

    /// The activation for a file open right now: the stored choice combined
    /// with whether `app.preferredEditor` holds a command. Every entrypoint
    /// that opens a file from the tree, the right sidebar, or a diff viewer
    /// resolves through here so the choice is honored identically.
    static func resolvedFileActivation(defaults: UserDefaults = .standard) -> FileExplorerFileActivation {
        fileActivation(
            action: resolvedAction(defaults: defaults),
            hasPreferredEditorCommand: PreferredEditorSettingsStore(defaults: defaults).resolvedCommand != nil
        )
    }
}
