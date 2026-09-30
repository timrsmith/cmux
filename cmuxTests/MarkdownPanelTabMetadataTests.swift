import AppKit
import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class MarkdownTabMetadataTestHost: FilePreviewTabMetadataHost {
    let bonsplitController: BonsplitController
    let panelId: UUID
    let tabId: TabID

    init(bonsplitController: BonsplitController, panelId: UUID, tabId: TabID) {
        self.bonsplitController = bonsplitController
        self.panelId = panelId
        self.tabId = tabId
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

/// The Markdown editor must project its dirty flag to the workspace tab through
/// the same synchronous seam the native file editor uses, so the modified dot
/// tracks the buffer the instant an edit or save lands.
@MainActor
@Suite(.serialized)
struct MarkdownPanelTabMetadataTests {
    @Test
    func editingMarkdownTextMarksTheWorkspaceTabDirtyAndSavingClearsIt() async throws {
        let url = try temporaryMarkdownFile(contents: "# Original\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        let panel = try #require(workspace.newMarkdownSurface(
            inPane: paneId,
            filePath: url.path,
            focus: false
        ))
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))
        if let load = panel.loadTextContent() {
            await load.value
        }
        #expect(workspace.bonsplitController.tab(tabId)?.isDirty == false)

        panel.updateTextContent("# Original\n\nEdited.\n")

        #expect(panel.isDirty)
        #expect(
            workspace.bonsplitController.tab(tabId)?.isDirty == true,
            "An edit must reach the tab synchronously through the shared tab-metadata seam"
        )

        if let save = panel.saveTextContent() {
            await save.value
        }

        #expect(!panel.isDirty)
        #expect(workspace.bonsplitController.tab(tabId)?.isDirty == false)
    }

    @Test
    func boundHostReceivesDirtyStateAndUnbindStopsProjection() async throws {
        let url = try temporaryMarkdownFile(contents: "# Original\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let panel = MarkdownPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        if let load = panel.loadTextContent() {
            await load.value
        }

        let host = try makeTabMetadataHost(for: panel.id)
        panel.bindTabMetadata(to: host)
        #expect(host.bonsplitController.tab(host.tabId)?.isDirty == false)
        #expect(host.bonsplitController.tab(host.tabId)?.title == url.lastPathComponent)

        panel.updateTextContent("# Original\n\nEdited.\n")
        #expect(host.bonsplitController.tab(host.tabId)?.isDirty == true)

        if let save = panel.saveTextContent() {
            await save.value
        }
        #expect(!panel.isDirty)
        #expect(host.bonsplitController.tab(host.tabId)?.isDirty == false)

        panel.updateTextContent("# Original\n\nEdited again.\n")
        #expect(host.bonsplitController.tab(host.tabId)?.isDirty == true)
        panel.unbindTabMetadata()
        panel.updateTextContent("# Original\n\nEdited.\n")
        #expect(!panel.isDirty)
        #expect(
            host.bonsplitController.tab(host.tabId)?.isDirty == true,
            "An unbound panel must not keep projecting into its old host"
        )
    }

    private func makeTabMetadataHost(for panelId: UUID) throws -> MarkdownTabMetadataTestHost {
        let controller = BonsplitController()
        let paneId = try #require(controller.allPaneIds.first)
        let tabId = try #require(controller.createTab(title: "Unbound markdown", inPane: paneId))
        return MarkdownTabMetadataTestHost(bonsplitController: controller, panelId: panelId, tabId: tabId)
    }

    private func temporaryMarkdownFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("md")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
