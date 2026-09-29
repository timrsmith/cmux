import CmuxSettings
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavioral coverage for the `terminalEditor` file activation: the editor
/// resolution chain (`fileEditor.terminalEditorCommand`, `$VISUAL`, `$EDITOR`,
/// `vi`), the terminal request it builds (quoted path, working directory),
/// the Files header's Editor submenu rows, and the cmux.json parse path for
/// the new key.
///
/// Opening the terminal surface itself is `Workspace.openFileInTerminalEditor`,
/// a one-line forward of the request into `newTerminalSurface`; it is exercised
/// by the tagged dev build.
final class TerminalEditorCommandResolverTests: XCTestCase {
    private let terminalEditorCommandKey = FileEditorCatalogSection().terminalEditorCommand.userDefaultsKey
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    private func resolver(
        configured: String = "",
        environment: [String: String] = [:]
    ) -> TerminalEditorCommandResolver {
        TerminalEditorCommandResolver(configuredCommand: configured, environment: environment)
    }

    // MARK: - Resolution chain

    func testConfiguredCommandWinsOverEnvironment() {
        let resolution = resolver(
            configured: "  hx --vsplit  ",
            environment: ["VISUAL": "nvim", "EDITOR": "nano"]
        ).resolution
        XCTAssertEqual(resolution.command, "hx --vsplit")
        XCTAssertEqual(resolution.source, .setting)
    }

    func testVisualWinsOverEditorWhenNoCommandIsConfigured() {
        let resolution = resolver(environment: ["VISUAL": "nvim", "EDITOR": "nano"]).resolution
        XCTAssertEqual(resolution.command, "nvim")
        XCTAssertEqual(resolution.source, .visual)
    }

    func testEditorIsUsedWhenVisualIsBlank() {
        let resolution = resolver(configured: "   ", environment: ["VISUAL": " ", "EDITOR": "nano"]).resolution
        XCTAssertEqual(resolution.command, "nano")
        XCTAssertEqual(resolution.source, .editor)
    }

    func testFallsBackToViWhenNothingIsSet() {
        let resolution = resolver(environment: ["PATH": "/usr/bin"]).resolution
        XCTAssertEqual(resolution.command, "vi")
        XCTAssertEqual(resolution.source, .builtInFallback)
        XCTAssertEqual(TerminalEditorCommandResolver.builtInFallbackCommand, "vi")
    }

    func testProductionInitializerReadsTheCatalogKey() {
        let suiteName = "cmux-terminal-editor-resolver-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("micro", forKey: terminalEditorCommandKey)

        let resolution = TerminalEditorCommandResolver(defaults: defaults, environment: ["EDITOR": "nano"]).resolution
        XCTAssertEqual(resolution.command, "micro")
        XCTAssertEqual(resolution.source, .setting)
    }

    // MARK: - Display name

    func testDisplayNameIsTheExecutableBasename() {
        XCTAssertEqual(resolver(configured: "/opt/homebrew/bin/nvim -u NONE").resolution.displayName, "nvim")
        XCTAssertEqual(resolver(configured: "emacs -nw").resolution.displayName, "emacs")
        XCTAssertEqual(resolver(configured: "'/Applications/My Editor.app/Contents/MacOS/edit' --wait").resolution.displayName, "edit")
        XCTAssertEqual(resolver().resolution.displayName, "vi")
    }

    // MARK: - Open request

    func testOpenRequestQuotesThePathAndStartsInItsDirectory() {
        let request = resolver(configured: "nvim").openRequest(forFilePath: "/Users/alice/proj/it's here/main.swift")
        XCTAssertEqual(request.command, "nvim '/Users/alice/proj/it'\\''s here/main.swift'")
        XCTAssertEqual(request.workingDirectory, "/Users/alice/proj/it's here")
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

    func testEditorMenuListsEveryChoiceInPickerOrder() {
        let items = FilesPanelEditorMenuItems(terminalEditor: resolver(configured: "nvim").resolution).items
        XCTAssertEqual(items.map(\.action), [.preview, .terminalEditor, .defaultEditor, .preferredEditor])
        XCTAssertEqual(items.map(\.action), FileExplorerDoubleClickAction.allCases)
        XCTAssertEqual(items.map(\.title), ["Native Editor", "Terminal Editor", "Default App", "Preferred Editor App"])
    }

    func testEditorMenuNamesTheFallbackEditorWhenNoCommandIsConfigured() {
        let fromEnvironment = FilesPanelEditorMenuItems(terminalEditor: resolver(environment: ["EDITOR": "/usr/local/bin/nvim"]).resolution).items
        XCTAssertEqual(fromEnvironment[1].title, "Terminal Editor (nvim)")

        let builtIn = FilesPanelEditorMenuItems(terminalEditor: resolver().resolution).items
        XCTAssertEqual(builtIn[1].title, "Terminal Editor (vi)")
    }

    // MARK: - cmux.json

    func testTerminalEditorCommandIsAdvertisedAsASupportedSettingsPath() {
        XCTAssertTrue(CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("fileEditor.terminalEditorCommand"))
        XCTAssertTrue(CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("fileExplorer.doubleClickAction"))
    }

    func testSettingsFileStoreAppliesTerminalEditorCommand() throws {
        try withCleanManagedDefaults { defaults in
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
            let resolution = TerminalEditorCommandResolver(defaults: defaults, environment: ["EDITOR": "nano"]).resolution
            XCTAssertEqual(resolution.command, "emacs -nw")
        }
    }

    func testSettingsFileStoreIgnoresANonStringTerminalEditorCommand() throws {
        try withCleanManagedDefaults { defaults in
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
        }
    }

    // MARK: - Helpers

    private func withCleanManagedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let defaults = UserDefaults.standard
        let keys = [terminalEditorCommandKey, settingsFileBackupsDefaultsKey, importedManagedDefaultsKey]
        let previousValues = keys.reduce(into: [String: Any]()) { values, key in
            values[key] = defaults.object(forKey: key)
        }
        defer {
            for key in keys {
                if let value = previousValues[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        try body(defaults)
    }

    private func loadSettingsFile(_ contents: String) throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "terminal-editor-command-settings-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try contents.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
    }
}
