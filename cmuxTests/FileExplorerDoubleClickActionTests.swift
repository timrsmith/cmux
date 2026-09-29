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
/// values fall back to `preview`), UserDefaults round-tripping, and the
/// action-resolution function that maps a configured action plus the
/// preferred-editor availability to the concrete open behavior — including the
/// `preferredEditor` → `defaultEditor` fallback when no command is configured.
///
/// The NSOutlineView / NSTableView gesture wiring itself (doubleAction targets)
/// is AppKit-bound and not cleanly unit-testable; it is exercised manually and
/// not faked here.
@Suite struct FileExplorerDoubleClickActionTests {
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
        #expect(FileExplorerDoubleClickActionSettings.action(forRawValue: "defaultEditor") == .defaultEditor)
        #expect(FileExplorerDoubleClickActionSettings.action(forRawValue: "preferredEditor") == .preferredEditor)
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
        #expect(FileExplorerDoubleClickAction.defaultEditor.rawValue == "defaultEditor")
        #expect(FileExplorerDoubleClickAction.preferredEditor.rawValue == "preferredEditor")
        // Declaration order is the Settings picker and Files header menu order.
        #expect(
            FileExplorerDoubleClickAction.allCases == [.preview, .terminalEditor, .defaultEditor, .preferredEditor]
        )
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

    // MARK: - Action resolution (setting + preferred-editor availability)

    @Test func previewResolvesToPreviewRegardlessOfPreferredEditor() {
        for hasEditor in [true, false] {
            #expect(
                FileExplorerDoubleClickActionSettings.fileActivation(
                    action: .preview,
                    hasPreferredEditorCommand: hasEditor
                ) == .preview
            )
        }
    }

    @Test func defaultEditorResolvesToDefaultEditorRegardlessOfPreferredEditor() {
        for hasEditor in [true, false] {
            #expect(
                FileExplorerDoubleClickActionSettings.fileActivation(
                    action: .defaultEditor,
                    hasPreferredEditorCommand: hasEditor
                ) == .defaultEditor
            )
        }
    }

    @Test func preferredEditorResolvesToPreferredEditorWhenCommandConfigured() {
        #expect(
            FileExplorerDoubleClickActionSettings.fileActivation(
                action: .preferredEditor,
                hasPreferredEditorCommand: true
            ) == .preferredEditor
        )
    }

    @Test func preferredEditorFallsBackToDefaultEditorWhenNoCommand() {
        #expect(
            FileExplorerDoubleClickActionSettings.fileActivation(
                action: .preferredEditor,
                hasPreferredEditorCommand: false
            ) == .defaultEditor
        )
    }

    @Test func terminalEditorNeverFallsBack() {
        for hasEditor in [true, false] {
            #expect(
                FileExplorerDoubleClickActionSettings.fileActivation(
                    action: .terminalEditor,
                    hasPreferredEditorCommand: hasEditor
                ) == .terminalEditor
            )
        }
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

    @Test func resolvedFileActivationFoldsPreferredEditorWithoutACommandIntoDefaultEditor() {
        let defaults = makeDefaults()
        FileExplorerDoubleClickActionSettings.setAction(.preferredEditor, defaults: defaults, notificationCenter: NotificationCenter())
        #expect(FileExplorerDoubleClickActionSettings.resolvedFileActivation(defaults: defaults) == .defaultEditor)

        defaults.set("code --wait", forKey: AppCatalogSection().preferredEditor.userDefaultsKey)
        #expect(FileExplorerDoubleClickActionSettings.resolvedFileActivation(defaults: defaults) == .preferredEditor)
    }
}
