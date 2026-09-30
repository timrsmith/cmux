import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The app's reading of the file explorer double-click action setting
/// (`fileExplorer.doubleClickAction`): the parse wrapper's fallback to
/// `preview` for unknown values, UserDefaults round-tripping through the
/// catalog key, and the silent migration of the retired external-editor
/// values (`defaultEditor`, `preferredEditor`) from UserDefaults and from
/// cmux.json. The enum itself (cases, raw values, key id, legacy decode) is
/// covered by the CmuxSettings package suite of the same name.
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
        for action in FileExplorerDoubleClickAction.allCases {
            #expect(FileExplorerDoubleClickActionSettings.action(forRawValue: action.rawValue) == action)
        }
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

    /// The app's key and default are the catalog key's, so the Settings
    /// window and the file open path never disagree.
    @Test func storageMirrorsTheCatalogKey() {
        let key = FileExplorerCatalogSection().doubleClickAction
        #expect(FileExplorerDoubleClickActionSettings.key == key.userDefaultsKey)
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

    // MARK: - Migration from the removed external choices

    /// The choices that opened a file outside cmux (`defaultEditor`,
    /// `preferredEditor`) are gone; the native editor offers Open With and
    /// Open Externally itself. A value stored by an earlier build must keep
    /// working silently as the native editor.
    @Test(arguments: ["defaultEditor", "preferredEditor"])
    func legacyExternalRawValuesResolveToPreview(raw: String) {
        #expect(FileExplorerDoubleClickActionSettings.action(forRawValue: raw) == .preview)

        let defaults = makeDefaults()
        defaults.set(raw, forKey: FileExplorerDoubleClickActionSettings.key)
        #expect(FileExplorerDoubleClickActionSettings.resolvedAction(defaults: defaults) == .preview)
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
