import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `TabManager` forwards every Edit > Find command to the one focused
/// `FindablePanel`; each panel kind owns its find UI. These tests drive real
/// panels through `TabManager` because the focused panel is resolved from the
/// workspace tree rather than injected.
@MainActor
@Suite(.serialized)
struct FindablePanelRoutingTests {
    /// A spy that records the protocol calls, so a test can check the
    /// existential dispatch a `TabManager` forward goes through.
    private final class FindablePanelSpy: FindablePanel {
        var calls: [String] = []
        var isFindVisible = false
        var canUseSelectionForFind = false

        func startFind(replace: Bool) -> Bool {
            calls.append("startFind(replace: \(replace))")
            return true
        }
        func findNext() { calls.append("findNext") }
        func findPrevious() { calls.append("findPrevious") }
        func useSelectionForFind() -> Bool {
            calls.append("useSelectionForFind")
            return true
        }
        func hideFind() { calls.append("hideFind") }
    }

    private func makeManagerWithWorkspace() -> (TabManager, Workspace) {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        return (manager, workspace)
    }

    private func writeTemporaryFile(named name: String, contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-findable-panel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("Every protocol member dispatches through the existential")
    func existentialDispatchReachesEveryMember() {
        let spy = FindablePanelSpy()
        let panel: any FindablePanel = spy
        #expect(panel.startFind(replace: true))
        panel.findNext()
        panel.findPrevious()
        #expect(panel.useSelectionForFind())
        panel.hideFind()
        spy.isFindVisible = true
        spy.canUseSelectionForFind = true
        #expect(panel.isFindVisible)
        #expect(panel.canUseSelectionForFind)
        #expect(spy.calls == [
            "startFind(replace: true)",
            "findNext",
            "findPrevious",
            "useSelectionForFind",
            "hideFind"
        ])
    }

    @Test("With no focused findable panel every command is a no-op")
    func noFocusedPanelAnswersNothing() {
        let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false)
        #expect(manager.focusedFindablePanel == nil)
        #expect(!manager.isFindVisible)
        #expect(!manager.canUseSelectionForFind)
        #expect(!manager.startSearch())
        #expect(!manager.startSearch(replace: true))
        manager.searchSelection()
        manager.findNext()
        manager.findPrevious()
        manager.hideFind()
    }

    @Test("A focused text file preview is the findable panel and find reaches its editor")
    func filePreviewTextEditorAnswersFind() throws {
        let fileURL = try writeTemporaryFile(named: "notes.txt", contents: "needle in the haystack")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let (manager, workspace) = makeManagerWithWorkspace()
        defer { workspace.teardownAllPanels() }
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panel = try #require(workspace.newFilePreviewSurface(inPane: pane, filePath: fileURL.path, focus: true))
        try #require(panel.previewMode == .text)
        #expect(workspace.focusedPanelId == panel.id)
        #expect(manager.focusedFindablePanel === panel)

        #expect(!manager.startSearch(), "no editor attached yet")
        #expect(!manager.isFindVisible)

        let editor = makeWindowedEditor()
        defer { editor.close() }
        editor.textView.string = "needle in the haystack"
        panel.attachTextView(editor.textView)

        #expect(manager.startSearch())
        #expect(editor.scrollView.isFindBarVisible)
        #expect(manager.isFindVisible)
        #expect(!manager.canUseSelectionForFind)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 6))
        #expect(manager.canUseSelectionForFind)
        manager.searchSelection()
        manager.findNext()
        manager.findPrevious()
        manager.hideFind()
        #expect(!editor.scrollView.isFindBarVisible)
        #expect(!manager.isFindVisible)

        #expect(manager.startSearch(replace: true))
        #expect(editor.scrollView.isFindBarVisible)
        manager.hideFind()

        editor.textView.isEditable = false
        #expect(manager.startSearch(replace: true), "a read-only editor still gets plain find")
        #expect(editor.scrollView.isFindBarVisible)
    }

    @Test("A markdown panel finds in its preview or its text editor by display mode")
    func markdownPanelRoutesByDisplayMode() throws {
        let fileURL = try writeTemporaryFile(named: "README.md", contents: "# needle")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let (manager, workspace) = makeManagerWithWorkspace()
        defer { workspace.teardownAllPanels() }
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panel = try #require(workspace.newMarkdownSurface(inPane: pane, filePath: fileURL.path, focus: true))
        #expect(workspace.focusedPanelId == panel.id)
        #expect(manager.focusedFindablePanel === panel)
        try #require(panel.displayMode == .preview)

        #expect(!manager.isFindVisible)
        #expect(manager.startSearch(), "preview mode opens the in-page find bar")
        #expect(panel.searchState != nil)
        #expect(manager.isFindVisible)
        #expect(!manager.canUseSelectionForFind, "the rendered preview has no selection source")
        manager.hideFind()
        #expect(panel.searchState == nil)
        #expect(!manager.isFindVisible)

        panel.setDisplayMode(.text)
        #expect(manager.focusedFindablePanel === panel, "the same panel stays the findable panel in text mode")
        #expect(!manager.startSearch(), "text mode with no editor attached cannot show a find bar")
        #expect(panel.searchState == nil, "text mode never opens the preview find bar")

        let editor = makeWindowedEditor()
        defer { editor.close() }
        editor.textView.string = "# needle"
        panel.attachTextView(editor.textView)
        #expect(manager.startSearch())
        #expect(editor.scrollView.isFindBarVisible)
        #expect(manager.isFindVisible)
        #expect(panel.searchState == nil)
        editor.textView.setSelectedRange(NSRange(location: 2, length: 6))
        #expect(manager.canUseSelectionForFind)
        manager.hideFind()
        #expect(!editor.scrollView.isFindBarVisible)

        _ = manager.startSearch()
        panel.setDisplayMode(.preview)
        #expect(!manager.isFindVisible, "back in preview, the editor's find bar no longer counts")
        #expect(!manager.canUseSelectionForFind)
    }
}
