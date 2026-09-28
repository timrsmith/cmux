import Testing
@testable import CmuxSettings

@Suite("RightSidebarPosition")
struct RightSidebarPositionTests {
    @Test func defaultKeepsTheRightSidebarOnTheTrailingEdge() {
        let key = SidebarCatalogSection().rightPosition
        #expect(key.id == "sidebar.rightPosition")
        #expect(key.defaultValue == .trailing)
    }

    @Test func rawValuesMatchTheConfigSchema() {
        #expect(RightSidebarPosition.leading.rawValue == "leading")
        #expect(RightSidebarPosition.trailing.rawValue == "trailing")
        #expect(RightSidebarPosition.allCases == [.leading, .trailing])
    }

    @Test func decodesEachKnownJSONValue() {
        #expect(RightSidebarPosition.decodeFromJSON("leading") == .leading)
        #expect(RightSidebarPosition.decodeFromJSON("trailing") == .trailing)
    }

    @Test func rejectsUnknownJSONValues() {
        for raw in ["", "left", "right", "Leading", "TRAILING", 1, true] as [Any] {
            #expect(RightSidebarPosition.decodeFromJSON(raw) == nil, "\(raw) should not decode")
        }
        #expect(RightSidebarPosition.decodeFromJSON(nil) == nil)
    }

    @Test func roundTripsThroughUserDefaultsEncoding() {
        for position in RightSidebarPosition.allCases {
            let encoded = position.encodeForUserDefaults()
            #expect(RightSidebarPosition.decodeFromUserDefaults(encoded) == position)
        }
    }
}
