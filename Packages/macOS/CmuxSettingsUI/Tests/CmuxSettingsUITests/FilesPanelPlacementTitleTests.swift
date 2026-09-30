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

    @Test("the stacked placement names the tree's position above the workspace list")
    func stackedTitle() {
        #expect(FilesPanelPlacement.stacked.localizedTitle == "Above Workspaces")
    }

    @Test("every placement has its own non-empty symbol")
    func symbolsAreDistinctAndPresent() {
        let symbols = FilesPanelPlacement.allCases.map(\.symbolName)
        #expect(symbols.allSatisfy { !$0.isEmpty })
        #expect(Set(symbols).count == FilesPanelPlacement.allCases.count)
    }

    @Test("each symbol fills the part of the rectangle where the tree sits")
    func symbolsPictureThePlacement() {
        #expect(FilesPanelPlacement.rightSidebar.symbolName == "rectangle.trailinghalf.inset.filled")
        #expect(FilesPanelPlacement.leading.symbolName == "rectangle.leadinghalf.inset.filled")
        #expect(FilesPanelPlacement.stacked.symbolName == "rectangle.tophalf.inset.filled")
    }
}
