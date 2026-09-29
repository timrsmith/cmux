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

/// Resolves which terminal editor the `terminalEditor` file activation runs,
/// and builds the terminal command for a file. Pure: the configured command
/// and the environment snapshot are injected, so the Files header menu, the
/// open path, and tests share one resolution.
///
/// Resolution order: `fileEditor.terminalEditorCommand` when non-blank, else
/// `$VISUAL`, else `$EDITOR` (blank values are skipped), else `vi`.
struct TerminalEditorCommandResolver: Equatable, Sendable {
    /// Where the resolved command came from.
    enum Source: Equatable, Sendable {
        /// `fileEditor.terminalEditorCommand`.
        case setting
        /// `$VISUAL` in the injected environment.
        case visual
        /// `$EDITOR` in the injected environment.
        case editor
        /// Nothing configured anywhere; ``builtInFallbackCommand``.
        case builtInFallback
    }

    /// One resolved editor command with its provenance.
    struct Resolution: Equatable, Sendable {
        let command: String
        let source: Source

        /// The editor's short name for menu titles: the basename of the
        /// command's first word (`/opt/homebrew/bin/nvim -u none` is `nvim`).
        var displayName: String {
            let executable: String
            if let quote = command.first, quote == "'" || quote == "\"",
               let closing = command.dropFirst().firstIndex(of: quote) {
                executable = String(command[command.index(after: command.startIndex)..<closing])
            } else if let firstWord = command.split(whereSeparator: \.isWhitespace).first {
                executable = String(firstWord)
            } else {
                executable = command
            }
            return (executable as NSString).lastPathComponent
        }
    }

    /// The editor every POSIX system ships.
    static let builtInFallbackCommand = "vi"

    let configuredCommand: String
    let environment: [String: String]

    /// Creates a resolver over explicit inputs.
    init(configuredCommand: String, environment: [String: String]) {
        self.configuredCommand = configuredCommand
        self.environment = environment
    }

    /// Creates the production resolver: the command from `defaults` and the
    /// app process environment (cmux has no login-shell environment capture;
    /// an app launched from the Dock sees only the values launchd gives it).
    init(defaults: UserDefaults, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(
            configuredCommand: FileEditorCatalogSection().terminalEditorCommand.value(in: defaults),
            environment: environment
        )
    }

    /// The resolved editor command.
    var resolution: Resolution {
        if let command = Self.nonBlank(configuredCommand) {
            return Resolution(command: command, source: .setting)
        }
        if let command = Self.nonBlank(environment["VISUAL"]) {
            return Resolution(command: command, source: .visual)
        }
        if let command = Self.nonBlank(environment["EDITOR"]) {
            return Resolution(command: command, source: .editor)
        }
        return Resolution(command: Self.builtInFallbackCommand, source: .builtInFallback)
    }

    /// The terminal request that opens `path` (made absolute) in the resolved editor.
    func openRequest(forFilePath path: String) -> TerminalEditorOpenRequest {
        let absolutePath = URL(fileURLWithPath: path).standardizedFileURL.path
        let directory = (absolutePath as NSString).deletingLastPathComponent
        return TerminalEditorOpenRequest(
            command: "\(resolution.command) \(TerminalStartupShellQuoting.singleQuoted(absolutePath))",
            workingDirectory: directory.isEmpty ? "/" : directory
        )
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
