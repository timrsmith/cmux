import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A tab-metadata host over a fresh Bonsplit controller holding one tab for
/// the panel under test, so a suite can read what a text editor projects to
/// its tab without a workspace.
@MainActor
final class FilePreviewTabMetadataTestHost: FilePreviewTabMetadataHost {
    let bonsplitController: BonsplitController
    let panelId: UUID
    let tabId: TabID

    /// Creates a host whose controller holds one unbound tab for `panelId`.
    init(panelId: UUID) throws {
        let controller = BonsplitController()
        let paneId = try #require(controller.allPaneIds.first)
        bonsplitController = controller
        self.panelId = panelId
        tabId = try #require(controller.createTab(title: "Unbound editor", inPane: paneId))
    }

    func filePreviewTabId(forPanelId panelId: UUID) -> TabID? {
        panelId == self.panelId ? tabId : nil
    }

    func filePreviewTabTitlePresentation(
        for metadata: FilePreviewTabMetadata,
        panelId _: UUID,
        existingTab _: Bonsplit.Tab
    ) -> (title: String?, hasCustomTitle: Bool?) {
        (metadata.title, false)
    }
}
