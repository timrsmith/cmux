import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The Markdown editor must project its dirty flag to the workspace tab through
/// the same synchronous seam the native file editor uses, so the modified dot
/// tracks the buffer the instant an edit or save lands.
@MainActor
@Suite(.serialized)
struct MarkdownPanelTabMetadataTests {
    @Test
    func editingMarkdownTextMarksTheWorkspaceTabDirtyAndSavingClearsIt() async throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
        let (panel, url) = try await UnsavedChangesTestPanels.makeLoadedMarkdownPanel { path in
            try #require(workspace.newMarkdownSurface(inPane: paneId, filePath: path, focus: false))
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))
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
        let (panel, url) = try await UnsavedChangesTestPanels.makeLoadedMarkdownPanel()
        defer { panel.close(); try? FileManager.default.removeItem(at: url) }

        let host = try FilePreviewTabMetadataTestHost(panelId: panel.id)
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
}
