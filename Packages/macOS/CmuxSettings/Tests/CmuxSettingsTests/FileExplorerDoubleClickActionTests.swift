import Testing
@testable import CmuxSettings

@Suite("FileExplorerDoubleClickAction")
struct FileExplorerDoubleClickActionTests {
    @Test func defaultOpensTheNativeEditor() {
        let key = FileExplorerCatalogSection().doubleClickAction
        #expect(key.id == "fileExplorer.doubleClickAction")
        #expect(key.userDefaultsKey == "fileExplorerDoubleClickAction")
        #expect(key.defaultValue == .preview)
    }

    @Test func onlyTheInCmuxChoicesRemain() {
        #expect(FileExplorerDoubleClickAction.preview.rawValue == "preview")
        #expect(FileExplorerDoubleClickAction.terminalEditor.rawValue == "terminalEditor")
        // Declaration order is the Settings picker order.
        #expect(FileExplorerDoubleClickAction.allCases == [.preview, .terminalEditor])
    }

    @Test func decodesEachCurrentValue() {
        for action in FileExplorerDoubleClickAction.allCases {
            #expect(FileExplorerDoubleClickAction.decodeFromJSON(action.rawValue) == action)
            #expect(FileExplorerDoubleClickAction.decodeFromUserDefaults(action.encodeForUserDefaults()) == action)
        }
    }

    /// Earlier builds offered two choices that opened the file outside cmux
    /// (`defaultEditor`, `preferredEditor`). A stored value from that time must
    /// keep working silently as the native editor, from UserDefaults and from
    /// cmux.json alike.
    @Test(arguments: ["defaultEditor", "preferredEditor"])
    func legacyExternalValuesResolveToTheNativeEditor(raw: String) {
        #expect(FileExplorerDoubleClickAction.decodeFromUserDefaults(raw) == .preview)
        #expect(FileExplorerDoubleClickAction.decodeFromJSON(raw) == .preview)
        #expect(FileExplorerDoubleClickAction(rawValue: raw) == nil, "legacy values are not cases")
    }

    @Test func rejectsUnknownValues() {
        for raw in ["", "Preview", "PREVIEW", "editor", "default", "preferred", "finder", 1, true] as [Any] {
            #expect(FileExplorerDoubleClickAction.decodeFromJSON(raw) == nil, "\(raw) should not decode")
            #expect(FileExplorerDoubleClickAction.decodeFromUserDefaults(raw) == nil, "\(raw) should not decode")
        }
        #expect(FileExplorerDoubleClickAction.decodeFromJSON(nil) == nil)
        #expect(FileExplorerDoubleClickAction.decodeFromUserDefaults(nil) == nil)
    }
}
