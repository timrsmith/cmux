import Testing
@testable import CmuxSettings

@Suite("FilesPanelPlacement")
struct FilesPanelPlacementTests {
    @Test func defaultKeepsTheFileTreeInTheRightSidebar() {
        let key = SidebarCatalogSection().filesPanelPlacement
        #expect(key.id == "sidebar.filesPanelPlacement")
        #expect(key.userDefaultsKey == "filesPanelPlacement")
        #expect(key.defaultValue == .rightSidebar)
    }

    @Test func rawValuesMatchTheConfigSchema() {
        #expect(FilesPanelPlacement.rightSidebar.rawValue == "rightSidebar")
        #expect(FilesPanelPlacement.leading.rawValue == "leading")
        #expect(FilesPanelPlacement.allCases == [.rightSidebar, .leading])
    }

    @Test func decodesEachKnownJSONValue() {
        #expect(FilesPanelPlacement.decodeFromJSON("rightSidebar") == .rightSidebar)
        #expect(FilesPanelPlacement.decodeFromJSON("leading") == .leading)
    }

    @Test func rejectsUnknownJSONValues() {
        for raw in ["", "left", "right", "trailing", "Leading", "RIGHTSIDEBAR", "right-sidebar", 1, true] as [Any] {
            #expect(FilesPanelPlacement.decodeFromJSON(raw) == nil, "\(raw) should not decode")
        }
        #expect(FilesPanelPlacement.decodeFromJSON(nil) == nil)
    }

    @Test func roundTripsThroughUserDefaultsEncoding() {
        for placement in FilesPanelPlacement.allCases {
            let encoded = placement.encodeForUserDefaults()
            #expect(FilesPanelPlacement.decodeFromUserDefaults(encoded) == placement)
        }
    }
}
