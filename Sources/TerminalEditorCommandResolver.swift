import CmuxSettings
import Foundation

/// The terminal start request for opening one file in the terminal editor:
/// the shell command and the directory the terminal starts in.
struct TerminalEditorOpenRequest: Equatable, Sendable {
    /// ``TerminalEditorCommandResolver/command`` followed by the file's
    /// absolute path as one single-quoted ASCII word, ready for any login shell.
    let command: String
    /// The file's directory, so relative paths the editor shows make sense.
    let workingDirectory: String
}

/// Builds the terminal command the `terminalEditor` file activation runs.
/// Pure: the configured command is injected, so the Files header menu, the
/// open path, and tests share one resolution.
///
/// The editor is always started by `/bin/sh`, whether it is a non-blank
/// `fileEditor.terminalEditorCommand` or the ``shellFallbackExpression`` that
/// expands to `$VISUAL`, else `$EDITOR`, else `vi`. Resolving in the shell
/// rather than from the app's own environment matters because a Dock-launched
/// app rarely inherits the editor variables a user exports in a shell profile.
///
/// The open path wraps the whole line in the user's login shell, which may be
/// fish. Fish is not a POSIX shell: `${…:-…}` is not syntax, and `$(…)` only
/// exists from fish 3.4. So every shell-specific part lives inside the
/// single-quoted `sh -c` script, and the one argument that varies, the file
/// path, is an ASCII-only single-quoted word that every login shell reads as
/// the same literal string and `sh` decodes with `printf %b`.
struct TerminalEditorCommandResolver: Equatable, Sendable {
    /// The POSIX expression that picks the editor when no command is
    /// configured: `$VISUAL`, else `$EDITOR`, else `vi`. It is expanded
    /// unquoted so a multi-word value such as `code --wait` splits into
    /// arguments as it would at an interactive prompt.
    static let shellFallbackExpression = "${VISUAL:-${EDITOR:-vi}}"

    /// The command run when no editor is configured: ``launchLine(editor:)``
    /// over ``shellFallbackExpression``.
    static let shellFallbackCommand = launchLine(editor: shellFallbackExpression)

    /// `/bin/sh -c 'exec <editor> "$(printf %b "$1")"' cmux-editor`, ready
    /// for the ``encodedPathArgument(_:)`` that follows it as `$1`.
    ///
    /// `exec` leaves the editor as the terminal's foreground process, as a
    /// directly typed command would. Single quotes in `editor` are escaped
    /// as `'\''`, which POSIX shells and fish both read as a literal quote.
    static func launchLine(editor: String) -> String {
        let escapedEditor = editor.replacingOccurrences(of: "'", with: "'\\''")
        return "/bin/sh -c 'exec \(escapedEditor) \"$(printf %b \"$1\")\"' cmux-editor"
    }

    /// `path` as one single-quoted word of printable ASCII, for `printf %b`
    /// to decode inside `sh`: every byte at or above 0x80 and every
    /// backslash becomes `\0ooo`, and a single quote becomes `'\''`.
    ///
    /// No raw non-ASCII byte reaches the terminal's input, and the word means
    /// the same thing in every login shell: single quotes are literal in
    /// POSIX shells and in fish, whose only single-quote escapes are `\'` and
    /// `\\` (which is why a backslash is encoded rather than doubled).
    static func encodedPathArgument(_ path: String) -> String {
        var word = "'"
        for byte in path.utf8 {
            switch byte {
            case 0x27:
                word += "'\\''"
            case 0x5C, 0x80...:
                let octal = String(byte, radix: 8)
                word += "\\0" + String(repeating: "0", count: max(0, 3 - octal.count)) + octal
            default:
                word.unicodeScalars.append(Unicode.Scalar(byte))
            }
        }
        return word + "'"
    }

    let configuredCommand: String

    /// Creates a resolver over an explicit configured command.
    init(configuredCommand: String) {
        self.configuredCommand = configuredCommand
    }

    /// Creates the production resolver over the command stored in `defaults`.
    init(defaults: UserDefaults) {
        self.init(configuredCommand: FileEditorCatalogSection().terminalEditorCommand.value(in: defaults))
    }

    /// The trimmed configured command, or `nil` when it is blank and the shell
    /// fallback applies.
    var explicitCommand: String? {
        let trimmed = configuredCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The launch line that precedes the encoded file path:
    /// ``launchLine(editor:)`` over the explicit command, or
    /// ``shellFallbackCommand``.
    var command: String {
        Self.launchLine(editor: explicitCommand ?? Self.shellFallbackExpression)
    }

    /// The terminal request that opens `path` (made absolute) in the editor.
    func openRequest(forFilePath path: String) -> TerminalEditorOpenRequest {
        let absolutePath = URL(fileURLWithPath: path).standardizedFileURL.path
        let directory = (absolutePath as NSString).deletingLastPathComponent
        return TerminalEditorOpenRequest(
            command: "\(command) \(Self.encodedPathArgument(absolutePath))",
            workingDirectory: directory.isEmpty ? "/" : directory
        )
    }
}
