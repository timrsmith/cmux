import CmuxSettings
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavioral coverage for the `terminalEditor` file activation: the launch
/// line the resolver builds (a configured `fileEditor.terminalEditorCommand`,
/// else the `$VISUAL`/`$EDITOR`/`vi` expression, both run by `/bin/sh` with the
/// file path decoded from `$1`), the terminal request (working directory), the
/// line's shell-agnosticism, and the cmux.json parse path for the key.
///
/// Opening the terminal surface itself is `Workspace.openFileInTerminalEditor`,
/// a one-line forward of the request into `newTerminalSurface`; it is exercised
/// by the tagged dev build.
final class TerminalEditorCommandResolverTests: XCTestCase {
    private let terminalEditorCommandKey = FileEditorCatalogSection().terminalEditorCommand.userDefaultsKey

    /// The `/bin/sh` script every launch line runs: `exec <editor> <path>`, with
    /// the path decoded by `printf %b` from the octal-escaped `$1`.
    private func launchLine(editor: String) -> String {
        "/bin/sh -c 'exec \(editor) \"$(printf %b \"$1\")\"' cmux-editor"
    }

    private func resolver(configured: String = "") -> TerminalEditorCommandResolver {
        TerminalEditorCommandResolver(configuredCommand: configured)
    }

    // MARK: - Command resolution

    func testConfiguredCommandIsTrimmedAndRunUnderSh() {
        let resolver = resolver(configured: "  hx --vsplit  ")
        XCTAssertEqual(resolver.explicitCommand, "hx --vsplit")
        XCTAssertEqual(resolver.command, launchLine(editor: "hx --vsplit"))
    }

    func testBlankCommandFallsBackToTheShellExpressionUnderSh() {
        let fallback = launchLine(editor: "${VISUAL:-${EDITOR:-vi}}")
        for configured in ["", "   ", "\n\t"] {
            let resolver = resolver(configured: configured)
            XCTAssertNil(resolver.explicitCommand, configured.debugDescription)
            XCTAssertEqual(resolver.command, fallback, configured.debugDescription)
        }
        XCTAssertEqual(TerminalEditorCommandResolver.shellFallbackExpression, "${VISUAL:-${EDITOR:-vi}}")
        XCTAssertEqual(TerminalEditorCommandResolver.shellFallbackCommand, fallback)
        // The expansion is confined to `/bin/sh`: the surrounding login shell,
        // which may be fish, sees only literal words.
        XCTAssertFalse(fallback.hasPrefix("$"))
        XCTAssertTrue(fallback.hasPrefix("/bin/sh -c '"))
    }

    func testAConfiguredCommandWithQuotesStaysInsideTheShScript() {
        let request = resolver(configured: "code --wait --user-data-dir 'my dir'")
            .openRequest(forFilePath: "/tmp/a.txt")
        XCTAssertEqual(
            request.command,
            launchLine(editor: "code --wait --user-data-dir '\\''my dir'\\''") + " '/tmp/a.txt'"
        )
    }

    func testProductionInitializerReadsTheCatalogKey() {
        let suiteName = "cmux-terminal-editor-resolver-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(TerminalEditorCommandResolver(defaults: defaults).explicitCommand)
        defaults.set("micro", forKey: terminalEditorCommandKey)
        XCTAssertEqual(TerminalEditorCommandResolver(defaults: defaults).explicitCommand, "micro")
        XCTAssertEqual(TerminalEditorCommandResolver(defaults: defaults).command, launchLine(editor: "micro"))
    }

    // MARK: - Open request

    func testOpenRequestQuotesThePathAndStartsInItsDirectory() {
        let request = resolver(configured: "nvim").openRequest(forFilePath: "/Users/alice/proj/it's here/main.swift")
        XCTAssertEqual(
            request.command,
            launchLine(editor: "nvim") + " '/Users/alice/proj/it'\\''s here/main.swift'"
        )
        XCTAssertEqual(request.workingDirectory, "/Users/alice/proj/it's here")
    }

    func testOpenRequestPassesTheQuotedPathAsTheShellFallbackArgument() {
        let request = resolver().openRequest(forFilePath: "/Users/alice/proj/main.swift")
        XCTAssertEqual(
            request.command,
            launchLine(editor: "${VISUAL:-${EDITOR:-vi}}") + " '/Users/alice/proj/main.swift'"
        )
        XCTAssertEqual(request.workingDirectory, "/Users/alice/proj")
    }

    func testOpenRequestKeepsNonASCIIPathsOutOfTheLoginShellsSyntax() {
        // Every UTF-8 byte at or above 0x80 becomes `\0ooo` for `printf %b`.
        XCTAssertEqual(
            TerminalEditorCommandResolver.encodedPathArgument("/Users/alice/r\u{E9}sum\u{E9}/notes.md"),
            "'/Users/alice/r\\0303\\0251sum\\0303\\0251/notes.md'"
        )
        // `URL.standardizedFileURL.path` may hand back the path in decomposed
        // form, so the request is compared against the encoder over that path.
        let path = "/Users/alice/résumé/notes.md"
        let request = resolver(configured: "vim").openRequest(forFilePath: path)
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        XCTAssertEqual(
            request.command,
            launchLine(editor: "vim") + " " + TerminalEditorCommandResolver.encodedPathArgument(standardized)
        )
        XCTAssertFalse(request.command.contains("é"), "raw non-ASCII bytes must not reach the shell line")
        XCTAssertTrue(request.command.unicodeScalars.allSatisfy { $0.isASCII }, request.command)
        // Everything after the sh script is a literal single-quoted ASCII word:
        // no `$(…)` for the login shell to parse (fish < 3.4 has none) and no
        // `\\`, which fish collapses inside single quotes and POSIX shells keep.
        let afterScript = request.command.components(separatedBy: "' cmux-editor ").last ?? ""
        XCTAssertFalse(afterScript.contains("$"), afterScript)
        XCTAssertFalse(request.command.contains("\\\\"), request.command)
        XCTAssertEqual(request.workingDirectory, "/Users/alice/résumé")
    }

    func testOpenRequestEncodesBackslashesAsOctalTooSoEveryShellReadsTheSameWord() {
        let request = resolver(configured: "vim").openRequest(forFilePath: "/tmp/back\\slash/100%/notes.md")
        XCTAssertEqual(request.command, launchLine(editor: "vim") + " '/tmp/back\\0134slash/100%/notes.md'")
    }

    func testOpenRequestMakesRelativePathsAbsolute() {
        let request = resolver(configured: "vi").openRequest(forFilePath: "/tmp/../etc/hosts")
        XCTAssertEqual(request.command, launchLine(editor: "vi") + " '/etc/hosts'")
        XCTAssertEqual(request.workingDirectory, "/etc")
    }

    func testOpenRequestForARootFileStartsAtRoot() {
        let request = resolver(configured: "vi").openRequest(forFilePath: "/hosts")
        XCTAssertEqual(request.workingDirectory, "/")
    }

    // MARK: - The launch line under real shells

    /// Runs the launch line the way the login shell wrapper does (`<shell> -c`)
    /// under every shell on this Mac, with `/usr/bin/printf %s` standing in for
    /// the editor so its one argument comes back on stdout. The path exercises
    /// non-ASCII, a single quote, double quotes, `%`, a backslash, `$HOME` and
    /// backticks; each shell must hand the editor the exact same path.
    func testTheLaunchLineHandsTheEditorTheExactPathUnderEveryShell() throws {
        let path = "/tmp/résumé/it's \"here\"/100% back\\slash $HOME `x`/notes.md"
        let request = resolver(configured: "/usr/bin/printf %s").openRequest(forFilePath: path)
        let expected = URL(fileURLWithPath: path).standardizedFileURL.path
        XCTAssertTrue(expected.contains("résumé"))

        let shells = ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
        var exercised: [String] = []
        for shell in shells where FileManager.default.isExecutableFile(atPath: shell) {
            XCTAssertEqual(try output(ofShell: shell, running: request.command), expected, shell)
            exercised.append(shell)
        }
        XCTAssertTrue(exercised.contains("/bin/sh"), "\(exercised)")
        XCTAssertTrue(exercised.contains("/bin/zsh"), "\(exercised)")
    }

    private func output(ofShell shell: String, running command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - cmux.json

    func testTerminalEditorCommandIsAdvertisedAsASupportedSettingsPath() {
        XCTAssertTrue(CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("fileEditor.terminalEditorCommand"))
        XCTAssertTrue(CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("fileExplorer.doubleClickAction"))
    }

    func testSettingsFileStoreAppliesTerminalEditorCommand() throws {
        try withCleanManagedDefaults(clearing: [terminalEditorCommandKey]) { defaults in
            try loadSettingsFile(
                """
                {
                  "fileEditor": {
                    "terminalEditorCommand": "emacs -nw"
                  }
                }
                """
            )
            XCTAssertEqual(defaults.string(forKey: terminalEditorCommandKey), "emacs -nw")
            XCTAssertEqual(TerminalEditorCommandResolver(defaults: defaults).explicitCommand, "emacs -nw")
        }
    }

    func testSettingsFileStoreIgnoresANonStringTerminalEditorCommand() throws {
        try withCleanManagedDefaults(clearing: [terminalEditorCommandKey]) { defaults in
            try loadSettingsFile(
                """
                {
                  "fileEditor": {
                    "terminalEditorCommand": 3
                  }
                }
                """
            )
            XCTAssertNil(defaults.object(forKey: terminalEditorCommandKey))
            XCTAssertNil(TerminalEditorCommandResolver(defaults: defaults).explicitCommand)
        }
    }
}
