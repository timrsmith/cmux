import AppKit
import Bonsplit
import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Automation closes cannot answer the Save / Don't Save / Cancel prompt, so
/// they refuse instead: a socket, CLI, mobile-companion or AppleScript close
/// that would discard an editor's unsaved edits closes nothing and returns the
/// typed `unsaved_changes` error naming the file. An explicit force flag keeps
/// discarding, and the interactive paths are untouched.
@MainActor
@Suite(.serialized)
struct UnsavedChangesNonInteractiveCloseTests {
    // MARK: - Socket v2

    @Test
    func socketSurfaceCloseWithoutForceRefusesAndKeepsTheEditor() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let editor = try await fixture.openDirtyMarkdown()
        defer { try? FileManager.default.removeItem(at: editor.url) }

        let envelope = try fixture.socket(method: "surface.close", params: [
            "workspace_id": fixture.workspace.id.uuidString,
            "surface_id": editor.panel.id.uuidString,
        ])

        let error = try Self.expectError(envelope, code: "unsaved_changes")
        #expect((error["message"] as? String)?.contains(editor.url.lastPathComponent) == true)
        #expect(((error["data"] as? [String: Any])?["files"] as? [String]) == [editor.url.lastPathComponent])
        #expect(fixture.workspace.panels[editor.panel.id] != nil)
        #expect(editor.panel.isDirty)
    }

    @Test
    func socketSurfaceCloseWithForceDiscardsTheEdits() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let editor = try await fixture.openDirtyMarkdown()
        defer { try? FileManager.default.removeItem(at: editor.url) }

        let envelope = try fixture.socket(method: "surface.close", params: [
            "workspace_id": fixture.workspace.id.uuidString,
            "surface_id": editor.panel.id.uuidString,
            "force": true,
        ])

        #expect(envelope["ok"] as? Bool == true, Comment(rawValue: "\(envelope)"))
        #expect(fixture.workspace.panels[editor.panel.id] == nil)
        #expect(try String(contentsOf: editor.url, encoding: .utf8) == "# Original\n")
    }

    @Test
    func socketWorkspaceCloseWithoutForceRefusesAndKeepsTheWorkspace() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let second = fixture.manager.addWorkspace(select: true, eagerLoadTerminal: false)
        let editor = try await fixture.openDirtyMarkdown(in: second)
        defer { try? FileManager.default.removeItem(at: editor.url) }

        let envelope = try fixture.socket(method: "workspace.close", params: [
            "workspace_id": second.id.uuidString,
        ])

        let error = try Self.expectError(envelope, code: "unsaved_changes")
        #expect((error["message"] as? String)?.contains(editor.url.lastPathComponent) == true)
        #expect(((error["data"] as? [String: Any])?["files"] as? [String]) == [editor.url.lastPathComponent])
        #expect(fixture.manager.tabs.contains { $0.id == second.id })
        #expect(editor.panel.isDirty)
    }

    @Test
    func socketWorkspaceCloseWithForceDiscardsTheEdits() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let second = fixture.manager.addWorkspace(select: true, eagerLoadTerminal: false)
        let editor = try await fixture.openDirtyMarkdown(in: second)
        defer { try? FileManager.default.removeItem(at: editor.url) }

        let envelope = try fixture.socket(method: "workspace.close", params: [
            "workspace_id": second.id.uuidString,
            "force": true,
        ])

        #expect(envelope["ok"] as? Bool == true, Comment(rawValue: "\(envelope)"))
        #expect(!fixture.manager.tabs.contains { $0.id == second.id })
        #expect(try String(contentsOf: editor.url, encoding: .utf8) == "# Original\n")
    }

    @Test
    func socketWindowCloseWithoutForceRefusesWhenAWorkspaceIsDirty() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let editor = try await fixture.openDirtyMarkdown()
        defer { try? FileManager.default.removeItem(at: editor.url) }

        let envelope = try fixture.socket(method: "window.close", params: [
            "window_id": fixture.windowId.uuidString,
        ])

        let error = try Self.expectError(envelope, code: "unsaved_changes")
        #expect(((error["data"] as? [String: Any])?["files"] as? [String]) == [editor.url.lastPathComponent])
        #expect(fixture.workspace.panels[editor.panel.id] != nil)
        #expect(editor.panel.isDirty)
    }

    @Test
    func socketTabActionBatchCloseRefusesWhenASiblingIsDirty() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let terminalId = try #require(fixture.workspace.panels.keys.first)
        let editor = try await fixture.openDirtyMarkdown()
        defer { try? FileManager.default.removeItem(at: editor.url) }

        let envelope = try fixture.socket(method: "tab.action", params: [
            "workspace_id": fixture.workspace.id.uuidString,
            "surface_id": terminalId.uuidString,
            "action": "close_others",
        ])

        let error = try Self.expectError(envelope, code: "unsaved_changes")
        #expect(((error["data"] as? [String: Any])?["files"] as? [String]) == [editor.url.lastPathComponent])
        #expect(fixture.workspace.panels[editor.panel.id] != nil)
        #expect(editor.panel.isDirty)
    }

    @Test
    func socketWorkspaceActionBatchCloseRefusesWhenAnotherWorkspaceIsDirty() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let second = fixture.manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let editor = try await fixture.openDirtyMarkdown(in: second)
        defer { try? FileManager.default.removeItem(at: editor.url) }

        let envelope = try fixture.socket(method: "workspace.action", params: [
            "workspace_id": fixture.workspace.id.uuidString,
            "action": "close_others",
        ])

        let error = try Self.expectError(envelope, code: "unsaved_changes")
        #expect(((error["data"] as? [String: Any])?["files"] as? [String]) == [editor.url.lastPathComponent])
        #expect(fixture.manager.tabs.contains { $0.id == second.id })
        #expect(editor.panel.isDirty)
    }

    // MARK: - Socket v1 (legacy string protocol)

    @Test
    func legacyCloseWorkspaceRefusesNamingTheFile() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let second = fixture.manager.addWorkspace(select: true, eagerLoadTerminal: false)
        let editor = try await fixture.openDirtyMarkdown(in: second)
        defer { try? FileManager.default.removeItem(at: editor.url) }

        let response = TerminalController.shared.handleSocketLine("close_workspace \(second.id.uuidString)")

        #expect(response.hasPrefix("ERROR:"), Comment(rawValue: response))
        #expect(response.contains(editor.url.lastPathComponent), Comment(rawValue: response))
        #expect(fixture.manager.tabs.contains { $0.id == second.id })
        #expect(editor.panel.isDirty)
    }

    @Test
    func legacyCloseSurfaceRefusesNamingTheFile() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let editor = try await fixture.openDirtyMarkdown()
        defer { try? FileManager.default.removeItem(at: editor.url) }

        let response = TerminalController.shared.handleSocketLine("close_surface \(editor.panel.id.uuidString)")

        #expect(response.hasPrefix("ERROR:"), Comment(rawValue: response))
        #expect(response.contains(editor.url.lastPathComponent), Comment(rawValue: response))
        #expect(fixture.workspace.panels[editor.panel.id] != nil)
        #expect(editor.panel.isDirty)
    }

    @Test
    func legacyCloseWindowRefusesNamingTheFile() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let editor = try await fixture.openDirtyMarkdown()
        defer { try? FileManager.default.removeItem(at: editor.url) }

        let response = TerminalController.shared.handleSocketLine("close_window \(fixture.windowId.uuidString)")

        #expect(response.hasPrefix("ERROR:"), Comment(rawValue: response))
        #expect(response.contains(editor.url.lastPathComponent), Comment(rawValue: response))
        #expect(fixture.workspace.panels[editor.panel.id] != nil)
        #expect(editor.panel.isDirty)
    }

    // MARK: - Mobile companion

    @Test
    func mobileWorkspaceCloseReturnsTheRefusalAsTheCommandError() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let second = fixture.manager.addWorkspace(select: true, eagerLoadTerminal: false)
        let editor = try await fixture.openDirtyMarkdown(in: second)
        defer { try? FileManager.default.removeItem(at: editor.url) }

        let result = TerminalController.shared.v2MobileWorkspaceClose(params: [
            "workspace_id": second.id.uuidString,
        ])

        guard case .err(let code, let message, let data) = result else {
            Issue.record("Expected the mobile close to be refused, got \(result)")
            return
        }
        #expect(code == "unsaved_changes")
        #expect(message.contains(editor.url.lastPathComponent), Comment(rawValue: message))
        #expect(((data as? [String: Any])?["files"] as? [String]) == [editor.url.lastPathComponent])
        #expect(fixture.manager.tabs.contains { $0.id == second.id })
        #expect(editor.panel.isDirty)
    }

    // MARK: - The shared decision (AppleScript asks this directly)

    @Test
    func sharedQueryNamesEveryDirtyPanelAndIgnoresCleanOnes() async throws {
        let (dirty, dirtyURL) = try await UnsavedChangesTestPanels.makeLoadedMarkdownPanel()
        defer { dirty.close(); try? FileManager.default.removeItem(at: dirtyURL) }
        let (clean, cleanURL) = try await UnsavedChangesTestPanels.makeLoadedFilePreviewPanel()
        defer { clean.close(); try? FileManager.default.removeItem(at: cleanURL) }
        let confirmation = UnsavedChangesCloseConfirmation(presenter: RecordingUnsavedChangesPresenter())

        #expect(confirmation.refusal(forClosing: [dirty, clean]) == nil)

        dirty.updateTextContent(Fixture.editedContents)
        let refusal = try #require(confirmation.refusal(forClosing: [clean, dirty]))
        #expect(refusal.fileNames == [dirtyURL.lastPathComponent])
        #expect(refusal.message.contains(dirtyURL.lastPathComponent))
        #expect(!refusal.message.contains("--force"), "The mobile and AppleScript wording has no flag to offer")
        #expect(refusal.commandLineMessage.contains("--force"))
    }

    @Test
    func workspaceTabCloseRefusesUnlessForced() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let editor = try await fixture.openDirtyMarkdown()
        defer { try? FileManager.default.removeItem(at: editor.url) }

        let outcome = fixture.workspace.requestNonInteractiveCloseTabRecordingHistory(editor.tabId, force: false)
        guard case .refused(let refusal) = outcome else {
            Issue.record("Expected a refusal, got \(outcome)")
            return
        }
        #expect(refusal.fileNames == [editor.url.lastPathComponent])
        #expect(fixture.workspace.panels[editor.panel.id] != nil)

        #expect(fixture.workspace.requestNonInteractiveCloseTabRecordingHistory(editor.tabId, force: true) == .closed)
        #expect(fixture.workspace.panels[editor.panel.id] == nil)
        #expect(try String(contentsOf: editor.url, encoding: .utf8) == "# Original\n")
    }

    @Test
    func tabManagerWorkspaceCloseRefusesUnlessForced() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let second = fixture.manager.addWorkspace(select: true, eagerLoadTerminal: false)
        let editor = try await fixture.openDirtyMarkdown(in: second)
        defer { try? FileManager.default.removeItem(at: editor.url) }

        // The question AppleScript's `close` asks before closing a workspace.
        let refusal = try #require(fixture.manager.unsavedChangesRefusal(forClosing: [second]))
        #expect(refusal.fileNames == [editor.url.lastPathComponent])
        #expect(fixture.manager.unsavedChangesRefusal(forClosing: [fixture.workspace]) == nil)

        let outcome = fixture.manager.closeWorkspaceNonInteractively(second, force: false)
        #expect(outcome == .refused(refusal))
        #expect(fixture.manager.tabs.contains { $0.id == second.id })
        #expect(editor.panel.isDirty)

        #expect(fixture.manager.closeWorkspaceNonInteractively(second, force: true) == .closed)
        #expect(!fixture.manager.tabs.contains { $0.id == second.id })
    }

    // MARK: - Helpers

    private static func expectError(_ envelope: [String: Any], code: String) throws -> [String: Any] {
        #expect(envelope["ok"] as? Bool == false, Comment(rawValue: "\(envelope)"))
        let error = try #require(envelope["error"] as? [String: Any], Comment(rawValue: "\(envelope)"))
        #expect(error["code"] as? String == code, Comment(rawValue: "\(error)"))
        return error
    }

    /// A windowless main-window context the socket, mobile and AppleScript
    /// paths all resolve through, holding one workspace with a terminal.
    @MainActor
    private final class Fixture {
        static let editedContents = "# Original\n\nEdited.\n"

        let appDelegate: AppDelegate
        let manager: TabManager
        let workspace: Workspace
        let windowId: UUID
        private let previousAppDelegate: AppDelegate?
        private let previousManager: TabManager?

        init() throws {
            previousAppDelegate = AppDelegate.shared
            previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            appDelegate = AppDelegate()
            manager = TabManager(autoWelcomeIfNeeded: false)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            TerminalController.shared.setActiveTabManager(manager)
            windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            workspace = try #require(manager.tabs.first)
        }

        func tearDown() {
            TerminalController.shared.setActiveTabManager(previousManager)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            appDelegate.forgetRecoverableMainWindowRoute(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            AppDelegate.shared = previousAppDelegate
        }

        struct Editor {
            let panel: MarkdownPanel
            let tabId: TabID
            let url: URL
        }

        func openDirtyMarkdown(in target: Workspace? = nil) async throws -> Editor {
            let workspace = target ?? self.workspace
            let paneId = try #require(workspace.bonsplitController.allPaneIds.first)
            let (panel, url) = try await UnsavedChangesTestPanels.makeLoadedMarkdownPanel { path in
                try #require(workspace.newMarkdownSurface(inPane: paneId, filePath: path, focus: false))
            }
            panel.updateTextContent(Self.editedContents)
            let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))
            #expect(panel.isDirty)
            return Editor(panel: panel, tabId: tabId, url: url)
        }

        /// One v2 request through the real socket line handler.
        func socket(method: String, params: [String: Any]) throws -> [String: Any] {
            let request: [String: Any] = ["id": method, "method": method, "params": params]
            let requestData = try JSONSerialization.data(withJSONObject: request)
            let requestLine = try #require(String(data: requestData, encoding: .utf8))
            let raw = TerminalController.shared.handleSocketLine(requestLine)
            let responseData = try #require(raw.data(using: .utf8))
            return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        }
    }
}
