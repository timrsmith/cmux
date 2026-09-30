import CmuxSettings
import Testing
@testable import CmuxSettingsUI

@Suite("SettingsSectionID")
struct SettingsSectionIDTests {
    @Test func everyCaseHasNonEmptyTitleAndSymbol() {
        for section in SettingsSectionID.allCases {
            #expect(!section.title.isEmpty)
            #expect(!section.symbolName.isEmpty)
        }
    }

    @Test func titlesAreUnique() {
        let titles = SettingsSectionID.allCases.map(\.title)
        #expect(titles.count == Set(titles).count)
    }

    /// Devices keeps the persisted `computers` raw value and sits right after
    /// Cloud, so search ties and the detail stack follow the sidebar (#14771).
    @Test func devicesIsItsOwnSectionAfterCloud() {
        let cases = SettingsSectionID.allCases
        #expect(SettingsSectionID.computers.title == "Devices")
        #expect(SettingsSectionID(rawValue: "computers") == .computers)
        #expect(cases.firstIndex(of: .computers) == cases.firstIndex(of: .cloudMachines).map { $0 + 1 })
    }

    /// Anchors saved while Devices lived under Mobile select Devices and
    /// scroll to its header, whichever section the request named.
    @Test(arguments: [SettingsSectionID.mobile, .computers], ["setting:computers:pair", "setting:mobile:computers"])
    func legacyDevicesAnchorsLandOnTheDevicesHeader(target: SettingsSectionID, anchor: String) {
        let destination = target.navigationDestination(providedAnchor: anchor)
        #expect(destination.section == .computers)
        #expect(destination.anchorID == "section:computers")
    }

    /// Files and Editing gathers the file tree and file editor rows that used
    /// to live under App and Sidebar; `cmux settings open files-and-editing`
    /// and persisted selections use its raw value.
    @Test func filesAndEditingIsItsOwnSection() {
        #expect(SettingsSectionID.filesAndEditing.title == "Files and Editing")
        #expect(SettingsSectionID(rawValue: "filesAndEditing") == .filesAndEditing)
        #expect(SettingsSectionID.filesAndEditing.symbolName == "folder.badge.gearshape")
    }

    /// Anchors saved while the file rows lived under App or Sidebar select
    /// Files and Editing and scroll to the same row there, whichever section
    /// the request named.
    @Test(arguments: [
        (SettingsSectionID.app, "setting:app:file-explorer-double-click-action", "setting:filesAndEditing:file-explorer-double-click-action"),
        (.app, "setting:app:file-editor-terminal-editor-command", "setting:filesAndEditing:file-editor-terminal-editor-command"),
        (.app, "setting:app:file-editor-word-wrap", "setting:filesAndEditing:file-editor-word-wrap"),
        (.app, "setting:app:file-editor-tab-width", "setting:filesAndEditing:file-editor-tab-width"),
        (.sidebarAppearance, "setting:sidebarAppearance:files-panel-placement", "setting:filesAndEditing:files-panel-placement"),
        (.filesAndEditing, "setting:app:file-editor-line-numbers", "setting:filesAndEditing:file-editor-line-numbers")
    ])
    func legacyFileRowAnchorsLandOnTheirFilesAndEditingRow(target: SettingsSectionID, anchor: String, expected: String) {
        let destination = target.navigationDestination(providedAnchor: anchor)
        #expect(destination.section == .filesAndEditing)
        #expect(destination.anchorID == expected)
    }

    /// Every legacy file-row anchor redirects to a row the search index knows,
    /// so the redirected scroll has something to land on.
    @Test func legacyFileRowAnchorsResolveToIndexedRows() {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        let indexed = Set(index.entries.map(\.id))
        for (legacy, _) in SettingsSectionID.legacyFilesAndEditingAnchorIDs {
            let destination = SettingsSectionID.app.navigationDestination(providedAnchor: legacy)
            #expect(indexed.contains(destination.anchorID), "\(legacy) redirects to unknown row \(destination.anchorID)")
        }
    }

    @Test(arguments: SettingsSectionID.allCases)
    func missingAnchorLandsOnTheRequestedSectionHeader(section: SettingsSectionID) {
        let destination = section.navigationDestination(providedAnchor: nil)
        #expect(destination.section == section)
        #expect(destination.anchorID == "section:\(section.rawValue)")
    }

    @Test(arguments: [
        (SettingsSectionID.mobile, "setting:mobile:pairDevice"),
        (.computers, "setting:computers:discovery"),
        (.computers, "section:computers")
    ])
    func rowAnchorsArePreserved(section: SettingsSectionID, anchor: String) {
        let destination = section.navigationDestination(providedAnchor: anchor)
        #expect(destination.section == section)
        #expect(destination.anchorID == anchor)
    }

    @Test func notificationUserInfoResolvesTargetAndAnchor() throws {
        let legacy = try #require(SettingsSectionID.navigationDestination(userInfo: ["target": "mobile", "anchor": "setting:mobile:computers"]))
        #expect(legacy.section == .computers)
        #expect(legacy.anchorID == "section:computers")
        #expect(SettingsSectionID.navigationDestination(userInfo: ["target": "notASection"]) == nil)
        #expect(SettingsSectionID.navigationDestination(userInfo: nil) == nil)
    }
}
