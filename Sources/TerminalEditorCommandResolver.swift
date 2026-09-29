import CmuxSettings
import Foundation

/// The terminal start request for opening one file in the terminal editor:
/// the shell command and the directory the terminal starts in.
struct TerminalEditorOpenRequest: Equatable, Sendable {
    /// `<editor> <shell-quoted absolute path>`, ready for a POSIX shell.
    let command: String
    /// The file's directory, so relative paths the editor shows make sense.
    let workingDirectory: String
}

/// Builds the terminal command the `terminalEditor` file activation runs.
/// Pure: the configured command is injected, so the Files header menu, the
/// open path, and tests share one resolution.
///
/// A non-blank `fileEditor.terminalEditorCommand` is used verbatim. Otherwise
/// the command is ``shellFallbackCommand``, which lets `/bin/sh` expand
/// ``shellFallbackExpression`` to `$VISUAL`, else `$EDITOR`, else `vi` inside
/// the user's login shell (the open path wraps the command in one). Resolving
/// in the shell rather than from the app's own environment matters because a
/// Dock-launched app rarely inherits the editor variables a user exports in a
/// shell profile.
struct TerminalEditorCommandResolver: Equatable, Sendable {
    /// The POSIX expression that picks the editor when no command is
    /// configured: `$VISUAL`, else `$EDITOR`, else `vi`. It is expanded
    /// unquoted so a multi-word value such as `code --wait` splits into
    /// arguments as it would at an interactive prompt.
    static let shellFallbackExpression = "${VISUAL:-${EDITOR:-vi}}"

    /// The command run when no editor is configured. The expansion happens
    /// inside `/bin/sh` with the file path passed as `$1`, so the user's login
    /// shell, which wraps every command and may be fish (where `${…:-…}` is
    /// not syntax), only ever sees plain arguments. `exec` leaves the editor as
    /// the terminal's foreground process, as a directly configured one would be.
    static let shellFallbackCommand = "/bin/sh -c 'exec \(shellFallbackExpression) \"$1\"' cmux-editor"

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

    /// The command text that precedes the quoted file path: the explicit
    /// command, or ``shellFallbackCommand``.
    var command: String {
        explicitCommand ?? Self.shellFallbackCommand
    }

    /// The terminal request that opens `path` (made absolute) in the editor.
    func openRequest(forFilePath path: String) -> TerminalEditorOpenRequest {
        let absolutePath = URL(fileURLWithPath: path).standardizedFileURL.path
        let directory = (absolutePath as NSString).deletingLastPathComponent
        return TerminalEditorOpenRequest(
            command: "\(command) \(TerminalStartupShellQuoting.singleQuoted(absolutePath))",
            workingDirectory: directory.isEmpty ? "/" : directory
        )
    }
}
