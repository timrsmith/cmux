import CmuxSettings
import Testing

@testable import CmuxSettingsUI

@Suite("FilesPanelPlacement titles")
struct FilesPanelPlacementTitleTests {
    @Test("every placement has its own non-empty title")
    func titlesAreDistinctAndPresent() {
        let titles = FilesPanelPlacement.allCases.map(\.localizedTitle)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(Set(titles).count == FilesPanelPlacement.allCases.count)
    }

    @Test("the default placement reads as the right sidebar tab")
    func defaultTitle() {
        #expect(FilesPanelPlacement.rightSidebar.localizedTitle == "In Right Sidebar")
    }
}
