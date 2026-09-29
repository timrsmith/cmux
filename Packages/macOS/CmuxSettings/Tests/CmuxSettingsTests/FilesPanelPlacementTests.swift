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
        #expect(FilesPanelPlacement.stacked.rawValue == "stacked")
        #expect(FilesPanelPlacement.allCases == [.rightSidebar, .leading, .stacked])
    }

    @Test func decodesEachKnownJSONValue() {
        #expect(FilesPanelPlacement.decodeFromJSON("rightSidebar") == .rightSidebar)
        #expect(FilesPanelPlacement.decodeFromJSON("leading") == .leading)
        #expect(FilesPanelPlacement.decodeFromJSON("stacked") == .stacked)
    }

    @Test func onlyTheRightSidebarPlacementKeepsAFilesTab() {
        #expect(!FilesPanelPlacement.rightSidebar.isDetachedFromRightSidebar)
        #expect(FilesPanelPlacement.leading.isDetachedFromRightSidebar)
        #expect(FilesPanelPlacement.stacked.isDetachedFromRightSidebar)
    }

    @Test func rejectsUnknownJSONValues() {
        for raw in ["", "left", "right", "trailing", "Leading", "RIGHTSIDEBAR", "right-sidebar", "Stacked", "below", 1, true] as [Any] {
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
