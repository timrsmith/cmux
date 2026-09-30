import Bonsplit
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Close entry points route through the shared unsaved-changes confirmation:
/// the Bonsplit tab-close delegate (close button, shortcut, socket), the
/// context-menu batch close and the workspace close in `TabManager`.
@MainActor
@Suite(.serialized)
struct UnsavedChangesCloseEntryPointTests {
    @Test
    func tabCloseAsksOnceAndCancelKeepsTheTab() async throws {
        let fixture = try makeFixture(responses: [.cancel])
        let editor = try await fixture.openDirtyMarkdown()
        defer { try? FileManager.default.removeItem(at: editor.url) }

        #expect(!fixture.workspace.requestCloseTab(editor.tabId, force: false))
        await fixture.awaitResolution()

        #expect(fixture.presenter.prompts.count == 1)
        #expect(fixture.presenter.prompts.first?.title.contains(editor.url.lastPathComponent) == true)
        #expect(fixture.workspace.panelIdFromSurfaceId(editor.tabId) == editor.panel.id)
        #expect(editor.panel.isDirty)
    }

    @Test
    func tabCloseDontSaveClosesTheTabWithoutWriting() async throws {
        let fixture = try makeFixture(responses: [.dontSave])
        let editor = try await fixture.openDirtyMarkdown()
        defer { try? FileManager.default.removeItem(at: editor.url) }

        #expect(!fixture.workspace.requestCloseTab(editor.tabId, force: false))
        await fixture.awaitResolution()

        #expect(fixture.presenter.prompts.count == 1)
        #expect(fixture.workspace.panelIdFromSurfaceId(editor.tabId) == nil)
        #expect(try String(contentsOf: editor.url, encoding: .utf8) == "# Original\n")
    }

    @Test
    func tabCloseSaveWritesTheFileThenClosesTheTab() async throws {
        let fixture = try makeFixture(responses: [.save])
        let editor = try await fixture.openDirtyMarkdown()
        defer { try? FileManager.default.removeItem(at: editor.url) }

        #expect(!fixture.workspace.requestCloseTab(editor.tabId, force: false))
        await fixture.awaitResolution()

        #expect(fixture.presenter.prompts.count == 1)
        #expect(fixture.workspace.panelIdFromSurfaceId(editor.tabId) == nil)
        #expect(try String(contentsOf: editor.url, encoding: .utf8) == Fixture.editedContents)
    }

    @Test
    func tabCloseWithCloseWarningsOnShowsOnlyTheUnsavedPrompt() async throws {
        let fixture = try makeFixture(responses: [.dontSave], warnBeforeClosing: true)
        let editor = try await fixture.openDirtyMarkdown()
        defer { try? FileManager.default.removeItem(at: editor.url) }

        // The tab's close button warns unconditionally when its setting is on.
        fixture.workspace.markTabCloseButtonClose(surfaceId: editor.tabId)
        #expect(!fixture.workspace.requestCloseTab(editor.tabId, force: false))
        await fixture.awaitResolution()

        #expect(fixture.presenter.prompts.count == 1)
        #expect(fixture.closeWarningPrompts == 0, "The unsaved prompt replaces the close warning")
        #expect(fixture.workspace.panelIdFromSurfaceId(editor.tabId) == nil)
    }

    @Test
    func tabCloseWithCloseWarningsOnStillWarnsWhenNothingIsDirty() async throws {
        let fixture = try makeFixture(responses: [], warnBeforeClosing: true)
        let editor = try await fixture.openDirtyMarkdown()
        defer { try? FileManager.default.removeItem(at: editor.url) }
        if let save = editor.panel.saveTextContent() {
            await save.value
        }
        #expect(!editor.panel.isDirty)

        fixture.workspace.markTabCloseButtonClose(surfaceId: editor.tabId)
        #expect(!fixture.workspace.requestCloseTab(editor.tabId, force: false))
        await fixture.waitUntil { fixture.workspace.panelIdFromSurfaceId(editor.tabId) == nil }

        #expect(fixture.presenter.prompts.isEmpty)
        #expect(fixture.closeWarningPrompts == 1, "A clean editor keeps the existing close warning")
    }

    @Test
    func forcedTabCloseSkipsThePromptAndDiscards() async throws {
        let fixture = try makeFixture(responses: [.cancel])
        let editor = try await fixture.openDirtyMarkdown()
        defer { try? FileManager.default.removeItem(at: editor.url) }

        #expect(fixture.workspace.requestCloseTab(editor.tabId, force: true))

        #expect(fixture.presenter.prompts.isEmpty)
        #expect(fixture.workspace.panelIdFromSurfaceId(editor.tabId) == nil)
    }

    @Test
    func contextMenuBatchCloseAsksOnceForTheBatch() async throws {
        let fixture = try makeFixture(responses: [.dontSave], warnBeforeClosing: true)
        let first = try await fixture.openDirtyMarkdown()
        defer { try? FileManager.default.removeItem(at: first.url) }
        let second = try await fixture.openDirtyMarkdown()
        defer { try? FileManager.default.removeItem(at: second.url) }

        fixture.workspace.closeTabsFromContextMenu([first.tabId, second.tabId])
        await fixture.awaitResolution()

        #expect(fixture.presenter.prompts.count == 1)
        #expect(fixture.presenter.prompts.first?.fileNames.count == 2)
        #expect(fixture.closeWarningPrompts == 0)
        #expect(fixture.workspace.panelIdFromSurfaceId(first.tabId) == nil)
        #expect(fixture.workspace.panelIdFromSurfaceId(second.tabId) == nil)
    }

    @Test
    func workspaceCloseThroughTabManagerAsksAndCancelKeepsTheWorkspace() async throws {
        let fixture = try makeFixture(responses: [.cancel], warnBeforeClosing: true)
        let second = fixture.manager.addWorkspace(select: true, eagerLoadTerminal: false)
        let editor = try await fixture.openDirtyMarkdown(in: second)
        defer { try? FileManager.default.removeItem(at: editor.url) }

        #expect(!fixture.manager.closeWorkspaceWithConfirmation(second))
        await fixture.awaitResolution()

        #expect(fixture.presenter.prompts.count == 1)
        #expect(fixture.closeWarningPrompts == 0)
        #expect(fixture.manager.tabs.contains { $0.id == second.id })
        #expect(editor.panel.isDirty)
    }

    @Test
    func workspaceCloseThroughTabManagerDontSaveClosesWithoutASecondPrompt() async throws {
        let fixture = try makeFixture(responses: [.dontSave], warnBeforeClosing: true)
        let second = fixture.manager.addWorkspace(select: true, eagerLoadTerminal: false)
        let editor = try await fixture.openDirtyMarkdown(in: second)
        defer { try? FileManager.default.removeItem(at: editor.url) }

        #expect(!fixture.manager.closeWorkspaceWithConfirmation(second))
        await fixture.awaitResolution()

        #expect(fixture.presenter.prompts.count == 1)
        #expect(fixture.closeWarningPrompts == 0, "Don't Save already confirmed the close")
        #expect(!fixture.manager.tabs.contains { $0.id == second.id })
        #expect(try String(contentsOf: editor.url, encoding: .utf8) == "# Original\n")
    }

    // MARK: - Fixture

    @MainActor
    private final class Fixture {
        static let editedContents = "# Original\n\nEdited.\n"

        let manager: TabManager
        let workspace: Workspace
        let presenter: RecordingUnsavedChangesPresenter
        let confirmation: UnsavedChangesCloseConfirmation
        private(set) var closeWarningPrompts = 0

        init(
            manager: TabManager,
            workspace: Workspace,
            presenter: RecordingUnsavedChangesPresenter,
            confirmation: UnsavedChangesCloseConfirmation
        ) {
            self.manager = manager
            self.workspace = workspace
            self.presenter = presenter
            self.confirmation = confirmation
            manager.confirmCloseHandler = { [weak self] _, _, _ in
                self?.closeWarningPrompts += 1
                return true
            }
        }

        struct Editor {
            let panel: MarkdownPanel
            let tabId: TabID
            let url: URL
        }

        func openDirtyMarkdown(in target: Workspace? = nil) async throws -> Editor {
            let workspace = target ?? self.workspace
            let url = try UnsavedChangesTestFiles.temporaryMarkdownFile(contents: "# Original\n")
            let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
            let panel = try #require(workspace.newMarkdownSurface(
                inPane: paneId,
                filePath: url.path,
                focus: false
            ))
            if let load = panel.loadTextContent() {
                await load.value
            }
            panel.updateTextContent(Self.editedContents)
            let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))
            #expect(panel.isDirty)
            return Editor(panel: panel, tabId: tabId, url: url)
        }

        func awaitResolution() async {
            guard let resolution = confirmation.inFlightResolution else {
                Issue.record("Expected the unsaved-changes prompt to be in flight")
                return
            }
            await resolution.value
        }

        func waitUntil(_ condition: () -> Bool) async {
            for _ in 0..<200 where !condition() {
                await Task.yield()
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
        }
    }

    private func makeFixture(
        responses: [UnsavedChangesPromptResponse],
        warnBeforeClosing: Bool = false
    ) throws -> Fixture {
        let suiteName = "UnsavedChangesCloseEntryPointTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let app = SettingCatalog().app
        for key in [
            app.warnBeforeClosingTab,
            app.warnBeforeClosingTabXButton,
            app.warnBeforeClosingWorkspace,
            app.warnBeforeClosingWindow
        ] {
            defaults.set(warnBeforeClosing, forKey: key.userDefaultsKey)
        }
        let presenter = RecordingUnsavedChangesPresenter(responses: responses)
        let confirmation = UnsavedChangesCloseConfirmation(presenter: presenter)
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            settings: UserDefaultsSettingsClient(defaults: defaults),
            closeTabWarningDefaults: defaults,
            unsavedChangesCloseConfirmation: confirmation
        )
        let workspace = try #require(manager.selectedWorkspace)
        return Fixture(
            manager: manager,
            workspace: workspace,
            presenter: presenter,
            confirmation: confirmation
        )
    }
}
