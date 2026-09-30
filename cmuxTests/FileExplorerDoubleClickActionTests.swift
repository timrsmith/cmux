import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pure-logic coverage for the file explorer double-click action setting
/// (`fileExplorer.doubleClickAction`). Verifies parse/validation (unknown
/// values fall back to `preview`), UserDefaults round-tripping, the mapping
/// from the configured action to the concrete open behavior, and the silent
/// migration of the retired external-editor values (`defaultEditor`,
/// `preferredEditor`) to `preview`.
///
/// The NSOutlineView / NSTableView gesture wiring itself (doubleAction targets)
/// is AppKit-bound and not cleanly unit-testable; it is exercised manually and
/// not faked here.
@Suite(.serialized) struct FileExplorerDoubleClickActionTests: ManagedDefaultsTestSupport {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "cmux-file-explorer-double-click-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: - Parse / validation

    @Test func defaultIsPreview() {
        #expect(FileExplorerDoubleClickActionSettings.defaultValue == .preview)
    }

    @Test func parsesEachKnownRawValue() {
        #expect(FileExplorerDoubleClickActionSettings.action(forRawValue: "preview") == .preview)
        #expect(FileExplorerDoubleClickActionSettings.action(forRawValue: "terminalEditor") == .terminalEditor)
    }

    @Test func nilRawValueFallsBackToPreview() {
        #expect(FileExplorerDoubleClickActionSettings.action(forRawValue: nil) == .preview)
    }

    @Test func unknownRawValueFallsBackToPreview() {
        for raw in ["", "  ", "Preview", "PREVIEW", "editor", "default", "preferred", "garbage"] {
            #expect(
                FileExplorerDoubleClickActionSettings.action(forRawValue: raw) == .preview,
                "unknown raw value \(raw.debugDescription) should fall back to preview"
            )
        }
    }

    @Test func rawValuesMatchConfigSchema() {
        #expect(FileExplorerDoubleClickAction.preview.rawValue == "preview")
        #expect(FileExplorerDoubleClickAction.terminalEditor.rawValue == "terminalEditor")
    }

    @Test func storageKeyIsTheCatalogKey() {
        let key = FileExplorerCatalogSection().doubleClickAction
        #expect(key.id == "fileExplorer.doubleClickAction")
        #expect(FileExplorerDoubleClickActionSettings.key == key.userDefaultsKey)
        #expect(FileExplorerDoubleClickActionSettings.key == "fileExplorerDoubleClickAction")
        #expect(FileExplorerDoubleClickActionSettings.defaultValue == key.defaultValue)
    }

    // MARK: - UserDefaults round-trip

    @Test func resolvedActionDefaultsToPreviewWhenUnset() {
        let defaults = makeDefaults()
        #expect(FileExplorerDoubleClickActionSettings.resolvedAction(defaults: defaults) == .preview)
    }

    @Test func resolvedActionReadsStoredValue() {
        for action in FileExplorerDoubleClickAction.allCases {
            let defaults = makeDefaults()
            FileExplorerDoubleClickActionSettings.setAction(
                action,
                defaults: defaults,
                notificationCenter: NotificationCenter()
            )
            #expect(FileExplorerDoubleClickActionSettings.resolvedAction(defaults: defaults) == action)
        }
    }

    @Test func resolvedActionFallsBackForCorruptedStoredValue() {
        let defaults = makeDefaults()
        defaults.set("not-a-real-action", forKey: FileExplorerDoubleClickActionSettings.key)
        #expect(FileExplorerDoubleClickActionSettings.resolvedAction(defaults: defaults) == .preview)
    }

    // MARK: - Action resolution

    @Test func eachChoiceMapsToItsOwnActivation() {
        #expect(FileExplorerDoubleClickActionSettings.fileActivation(action: .preview) == .preview)
        #expect(FileExplorerDoubleClickActionSettings.fileActivation(action: .terminalEditor) == .terminalEditor)
    }

    // MARK: - The shared open path's resolution (Workspace.openFile reads this)

    @Test func resolvedFileActivationDefaultsToPreview() {
        #expect(FileExplorerDoubleClickActionSettings.resolvedFileActivation(defaults: makeDefaults()) == .preview)
    }

    @Test func resolvedFileActivationHonorsTheStoredTerminalEditorChoice() {
        let defaults = makeDefaults()
        FileExplorerDoubleClickActionSettings.setAction(.terminalEditor, defaults: defaults, notificationCenter: NotificationCenter())
        #expect(FileExplorerDoubleClickActionSettings.resolvedFileActivation(defaults: defaults) == .terminalEditor)
    }

    // MARK: - Migration from the removed external choices

    /// The choices that opened a file outside cmux (`defaultEditor`,
    /// `preferredEditor`) are gone; the native editor offers Open With and
    /// Open Externally itself. A value stored by an earlier build must keep
    /// working silently as the native editor.
    @Test func onlyTheInCmuxChoicesRemain() {
        #expect(FileExplorerDoubleClickAction.allCases == [.preview, .terminalEditor])
    }

    @Test(arguments: ["defaultEditor", "preferredEditor"])
    func legacyExternalRawValuesResolveToPreview(raw: String) {
        #expect(FileExplorerDoubleClickActionSettings.action(forRawValue: raw) == .preview)

        let defaults = makeDefaults()
        defaults.set(raw, forKey: FileExplorerDoubleClickActionSettings.key)
        #expect(FileExplorerDoubleClickActionSettings.resolvedAction(defaults: defaults) == .preview)
        #expect(FileExplorerDoubleClickActionSettings.resolvedFileActivation(defaults: defaults) == .preview)
    }

    @MainActor
    @Test(arguments: ["defaultEditor", "preferredEditor"])
    func legacyExternalValuesInCmuxJSONResolveToPreview(raw: String) throws {
        try withCleanManagedDefaults(clearing: [FileExplorerDoubleClickActionSettings.key]) { defaults in
            try loadSettingsFile(
                """
                {
                  "fileExplorer": {
                    "doubleClickAction": "\(raw)"
                  }
                }
                """
            )
            #expect(defaults.string(forKey: FileExplorerDoubleClickActionSettings.key) == "preview")
            #expect(FileExplorerDoubleClickActionSettings.resolvedAction(defaults: defaults) == .preview)
        }
    }
}
