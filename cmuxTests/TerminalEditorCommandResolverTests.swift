import CmuxSettings
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavioral coverage for the `terminalEditor` file activation: the command
/// the resolver builds (a configured `fileEditor.terminalEditorCommand`
/// verbatim, else the `$VISUAL`/`$EDITOR`/`vi` shell expression the login
/// shell expands), the terminal request (quoted path, working directory), the
/// Files header's Editor submenu row titles, and the cmux.json parse path for
/// the key.
///
/// Opening the terminal surface itself is `Workspace.openFileInTerminalEditor`,
/// a one-line forward of the request into `newTerminalSurface`; it is exercised
/// by the tagged dev build.
final class TerminalEditorCommandResolverTests: XCTestCase {
    private let terminalEditorCommandKey = FileEditorCatalogSection().terminalEditorCommand.userDefaultsKey

    private func resolver(configured: String = "") -> TerminalEditorCommandResolver {
        TerminalEditorCommandResolver(configuredCommand: configured)
    }

    // MARK: - Command resolution

    func testConfiguredCommandIsUsedVerbatimAfterTrimming() {
        let resolver = resolver(configured: "  hx --vsplit  ")
        XCTAssertEqual(resolver.explicitCommand, "hx --vsplit")
        XCTAssertEqual(resolver.command, "hx --vsplit")
    }

    func testBlankCommandFallsBackToTheShellExpressionUnderSh() {
        let fallback = "/bin/sh -c 'exec ${VISUAL:-${EDITOR:-vi}} \"$1\"' cmux-editor"
        for configured in ["", "   ", "\n\t"] {
            let resolver = resolver(configured: configured)
            XCTAssertNil(resolver.explicitCommand, configured.debugDescription)
            XCTAssertEqual(resolver.command, fallback, configured.debugDescription)
        }
        XCTAssertEqual(TerminalEditorCommandResolver.shellFallbackExpression, "${VISUAL:-${EDITOR:-vi}}")
        // The expansion is confined to `/bin/sh`: the surrounding login shell,
        // which may be fish, sees only literal words.
        XCTAssertFalse(fallback.hasPrefix("$"))
        XCTAssertTrue(fallback.hasPrefix("/bin/sh -c '"))
    }

    func testProductionInitializerReadsTheCatalogKey() {
        let suiteName = "cmux-terminal-editor-resolver-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(TerminalEditorCommandResolver(defaults: defaults).explicitCommand)
        defaults.set("micro", forKey: terminalEditorCommandKey)
        XCTAssertEqual(TerminalEditorCommandResolver(defaults: defaults).command, "micro")
    }

    // MARK: - Open request

    func testOpenRequestQuotesThePathAndStartsInItsDirectory() {
        let request = resolver(configured: "nvim").openRequest(forFilePath: "/Users/alice/proj/it's here/main.swift")
        XCTAssertEqual(request.command, "nvim '/Users/alice/proj/it'\\''s here/main.swift'")
        XCTAssertEqual(request.workingDirectory, "/Users/alice/proj/it's here")
    }

    func testOpenRequestPassesTheQuotedPathAsTheShellFallbackArgument() {
        let request = resolver().openRequest(forFilePath: "/Users/alice/proj/main.swift")
        XCTAssertEqual(
            request.command,
            "/bin/sh -c 'exec ${VISUAL:-${EDITOR:-vi}} \"$1\"' cmux-editor '/Users/alice/proj/main.swift'"
        )
        XCTAssertEqual(request.workingDirectory, "/Users/alice/proj")
    }

    func testOpenRequestKeepsNonASCIIPathsInsideOneShellWord() {
        let request = resolver(configured: "vim").openRequest(forFilePath: "/Users/alice/résumé/notes.md")
        XCTAssertTrue(request.command.hasPrefix("vim \"$(printf '"), request.command)
        XCTAssertFalse(request.command.contains("é"), "raw non-ASCII bytes must not reach the shell line")
        XCTAssertEqual(request.workingDirectory, "/Users/alice/résumé")
    }

    func testOpenRequestMakesRelativePathsAbsolute() {
        let request = resolver(configured: "vi").openRequest(forFilePath: "/tmp/../etc/hosts")
        XCTAssertEqual(request.command, "vi '/etc/hosts'")
        XCTAssertEqual(request.workingDirectory, "/etc")
    }

    func testOpenRequestForARootFileStartsAtRoot() {
        let request = resolver(configured: "vi").openRequest(forFilePath: "/hosts")
        XCTAssertEqual(request.workingDirectory, "/")
    }

    // MARK: - Files header Editor submenu

    private func menuTitles(configured: String) -> [String] {
        FileExplorerDoubleClickAction.allCases.map {
            FilesPanelEditorMenuItems.title(for: $0, configuredCommand: configured)
        }
    }

    func testEditorMenuTitlesEveryChoiceInPickerOrder() {
        XCTAssertEqual(FileExplorerDoubleClickAction.allCases, [.preview, .terminalEditor, .defaultEditor, .preferredEditor])
        XCTAssertEqual(
            menuTitles(configured: "nvim"),
            ["Native Editor", "Terminal Editor (nvim)", "Default App", "Preferred Editor App"]
        )
    }

    func testEditorMenuNamesTheShellResolutionWhenNoCommandIsConfigured() {
        XCTAssertEqual(
            menuTitles(configured: "  "),
            ["Native Editor", "Terminal Editor ($VISUAL, $EDITOR or vi)", "Default App", "Preferred Editor App"]
        )
    }

    func testEditorMenuNamesTheConfiguredCommandByItsExecutableBasename() {
        func terminalEditorTitle(_ configured: String) -> String {
            FilesPanelEditorMenuItems.title(for: .terminalEditor, configuredCommand: configured)
        }
        XCTAssertEqual(terminalEditorTitle("/opt/homebrew/bin/nvim -u NONE"), "Terminal Editor (nvim)")
        XCTAssertEqual(terminalEditorTitle("emacs -nw"), "Terminal Editor (emacs)")
        XCTAssertEqual(
            terminalEditorTitle("'/Applications/My Editor.app/Contents/MacOS/edit' --wait"),
            "Terminal Editor (edit)"
        )
        XCTAssertEqual(terminalEditorTitle("\"/usr/local/bin/hx\" --vsplit"), "Terminal Editor (hx)")
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
            XCTAssertEqual(TerminalEditorCommandResolver(defaults: defaults).command, "emacs -nw")
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
