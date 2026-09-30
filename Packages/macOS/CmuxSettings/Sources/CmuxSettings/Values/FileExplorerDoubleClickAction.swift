import Foundation

/// What activating a file in the file tree opens (`fileExplorer.doubleClickAction`).
///
/// Applies to a double-click in the tree, Return on a search result, and every
/// sidebar-style file open that shares the tree's routing (the right sidebar's
/// file preview, the diff viewer's Open in cmux). Directories are unaffected:
/// they always expand or collapse. The default, ``preview``, is the built-in
/// cmux editor, so existing users see no change. Declaration order is the
/// order the Settings picker lists the choices in.
///
/// Both choices keep the file inside cmux. Earlier builds also offered
/// `defaultEditor` (the macOS default app) and `preferredEditor` (the
/// `app.preferredEditor` command); the native editor's header now offers Open
/// With and Open Externally for the files it cannot edit, so those stored
/// values decode as ``preview`` (see ``legacyRawValues``).
public enum FileExplorerDoubleClickAction: String, CaseIterable, Sendable, SettingCodable {
    /// The built-in cmux file editor (the historical default).
    case preview
    /// A terminal surface in cmux running the user's terminal editor
    /// (`fileEditor.terminalEditorCommand`, else `$VISUAL`, `$EDITOR`, `vi`).
    case terminalEditor

    /// Raw values earlier builds stored for the removed external choices, each
    /// paired with the choice it now resolves to. `web/data/cmux.schema.json`
    /// carries the same mapping under `x-cmux-legacyValues`, so config
    /// validation accepts these strings without advertising them as choices.
    public static let legacyRawValues: [String: FileExplorerDoubleClickAction] = [
        "defaultEditor": .preview,
        "preferredEditor": .preview,
    ]

    /// Resolves a stored string: a current raw value, a legacy value folded
    /// into its replacement, or `nil` for anything else so the key default
    /// applies.
    private static func resolved(_ string: String) -> FileExplorerDoubleClickAction? {
        FileExplorerDoubleClickAction(rawValue: string) ?? legacyRawValues[string]
    }

    /// Decodes a stored `UserDefaults` value: the raw value of a current
    /// choice, or a legacy value folded into its replacement. Anything else
    /// (a non-string, an unknown string) is `nil`, so the key default applies.
    public static func decodeFromUserDefaults(_ raw: Any?) -> FileExplorerDoubleClickAction? {
        (raw as? String).flatMap(resolved)
    }

    /// The raw value, the form `decodeFromUserDefaults` reads back.
    public func encodeForUserDefaults() -> Any { rawValue }

    /// Decodes a cmux.json value the same way as `UserDefaults`. The parser
    /// stores the decoded choice, so a legacy value in the file is normalized
    /// to its replacement on import.
    public static func decodeFromJSON(_ raw: Any?) -> FileExplorerDoubleClickAction? {
        (raw as? String).flatMap(resolved)
    }

    /// The raw value, one of the schema's advertised choices.
    public func encodeForJSON() -> Any { rawValue }
}
