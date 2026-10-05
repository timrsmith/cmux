import AppKit
import CmuxFilePreviewCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The editor keeps the diff in view: the gutter marks the working-tree
/// changes against git's index and reverts a hunk on request, clicks on the
/// line numbers select whole lines, and a button on the selection hands the
/// lines to the agent prompt.
@MainActor
@Suite("File Preview change markers")
struct FilePreviewChangeMarkersTests {
    private static let base = "one\ntwo\nthree\nfour\n"
    private static let edited = "one\nTWO\nthree\nnew\nfour\n"

    private func makePanel(
        contents: String,
        base: String? = Self.base,
        promptInsertion: (@MainActor (PromptLineReference) -> Bool)? = nil
    ) async throws -> FilePreviewPanel {
        let url = try UnsavedChangesTestFiles.temporaryTextFile(contents: contents)
        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: url.path,
            startFileWatcher: false,
            modeResolver: { _ in .text },
            changeBaseReader: { _ in
                FilePreviewChangeBase(repoRoot: "/repo", relativePath: "docs/story.txt", content: base)
            },
            changeRecomputeDelay: .zero,
            promptInsertion: promptInsertion
        )
        await panel.loadTextContent().value
        await panel.awaitChangeTracking()
        return panel
    }

    /// An editor on `textView` with the gutter installed, visible and indexed.
    private func makeGutterEditor(text: String) -> (editor: WindowedFilePreviewEditor, gutter: FilePreviewLineNumberGutterView) {
        let editor = makeWindowedEditor()
        editor.textView.string = text
        FilePreviewTextEditor<FilePreviewPanel>.installChrome(on: editor.scrollView, textView: editor.textView)
        editor.scrollView.hasVerticalRuler = true
        editor.scrollView.rulersVisible = true
        let gutter = editor.scrollView.verticalRulerView as! FilePreviewLineNumberGutterView
        gutter.reloadLineIndex(from: text, textFont: editor.textView.font)
        editor.textView.layoutManager?.ensureLayout(for: editor.textView.textContainer!)
        editor.window.layoutIfNeeded()
        return (editor, gutter)
    }

    private func gutterPoint(forLine line: Int, in gutter: FilePreviewLineNumberGutterView, textView: NSTextView) -> NSPoint {
        let layoutManager = textView.layoutManager!
        let index = FilePreviewLineIndex(string: textView.string)
        let glyph = layoutManager.glyphIndexForCharacter(at: index.offset(forLine: line))
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let textPoint = NSPoint(x: 0, y: rect.midY + textView.textContainerOrigin.y)
        let rulerPoint = gutter.convert(textPoint, from: textView)
        return NSPoint(x: gutter.ruleThickness - 4, y: rulerPoint.y)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in gutter: FilePreviewLineNumberGutterView, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: gutter.convert(point, to: nil),
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: gutter.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    @Test("Hunks come from the git base and follow the text as it changes")
    func hunksFollowTheText() async throws {
        let panel = try await makePanel(contents: Self.edited)
        let hunks = try #require(panel.changeHunks).hunks
        #expect(hunks.map(\.kind) == [.modified, .added])
        #expect(hunks.map(\.currentStart) == [2, 4])

        panel.updateTextContent(Self.base)
        await panel.awaitChangeTracking()
        #expect(panel.changeHunks?.isEmpty == true)
    }

    @Test("A file git does not track has no markers")
    func untrackedFileHasNoMarkers() async throws {
        let panel = try await makePanel(contents: Self.edited, base: nil)
        #expect(panel.changeHunks == nil)
    }

    @Test("Reverting a hunk through the editor restores the base lines and can be undone")
    func revertIsUndoable() async throws {
        let panel = try await makePanel(contents: Self.edited)
        let editor = makeWindowedEditor()
        defer { editor.close() }
        editor.textView.string = panel.textContent
        editor.textView.delegate = nil
        panel.attachTextView(editor.textView)
        let added = try #require(panel.changeHunks?.hunks.last)

        panel.revertChangeHunk(added)
        #expect(editor.textView.string == "one\nTWO\nthree\nfour\n")

        editor.textView.undoManager?.undo()
        #expect(editor.textView.string == Self.edited)
    }

    @Test("Clicking a line number selects the line; shift-click and drag extend the selection")
    func gutterClicksSelectLines() {
        let (editor, gutter) = makeGutterEditor(text: Self.edited)
        defer { editor.close() }
        let textView = editor.textView

        gutter.mouseDown(with: mouseEvent(.leftMouseDown, at: gutterPoint(forLine: 2, in: gutter, textView: textView), in: gutter))
        gutter.mouseUp(with: mouseEvent(.leftMouseUp, at: gutterPoint(forLine: 2, in: gutter, textView: textView), in: gutter))
        #expect(textView.selectedRange() == NSRange(location: 4, length: 4))
        #expect(gutter.selectedLineRange(in: textView) == 2...2)

        gutter.mouseDown(with: mouseEvent(.leftMouseDown, at: gutterPoint(forLine: 4, in: gutter, textView: textView), in: gutter, flags: .shift))
        gutter.mouseUp(with: mouseEvent(.leftMouseUp, at: gutterPoint(forLine: 4, in: gutter, textView: textView), in: gutter))
        #expect(gutter.selectedLineRange(in: textView) == 2...4)
        #expect(textView.selectedRange() == NSRange(location: 4, length: 14))

        gutter.mouseDown(with: mouseEvent(.leftMouseDown, at: gutterPoint(forLine: 3, in: gutter, textView: textView), in: gutter))
        gutter.mouseDragged(with: mouseEvent(.leftMouseDragged, at: gutterPoint(forLine: 1, in: gutter, textView: textView), in: gutter))
        gutter.mouseUp(with: mouseEvent(.leftMouseUp, at: gutterPoint(forLine: 1, in: gutter, textView: textView), in: gutter))
        #expect(gutter.selectedLineRange(in: textView) == 1...3)
    }

    @Test("The prompt button shows on a selection and hands the lines to the panel's prompt")
    func promptButtonHandsLinesToThePrompt() async throws {
        var inserted: [PromptLineReference] = []
        let panel = try await makePanel(contents: Self.edited) { reference in
            inserted.append(reference)
            return true
        }
        let (editor, gutter) = makeGutterEditor(text: panel.textContent)
        defer { editor.close() }
        FilePreviewTextEditor<FilePreviewPanel>.bindChangeMarkers(on: editor.scrollView, panel: panel)
        #expect(gutter.changeHunks == panel.changeHunks)
        #expect(!gutter.isPromptButtonVisible)

        gutter.selectLines(from: 2, to: 3, in: editor.textView)
        gutter.updatePromptButton()
        #expect(gutter.isPromptButtonVisible)

        gutter.performPromptButtonClick()
        #expect(inserted.map(\.promptText) == ["docs/story.txt:2-3 "])

        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        gutter.updatePromptButton()
        #expect(!gutter.isPromptButtonVisible)
    }

    @Test("The text area tints changed lines and rules deletion points, like the diff")
    func overlayRangesFollowTheHunks() async throws {
        let panel = try await makePanel(contents: Self.edited)
        let (editor, gutter) = makeGutterEditor(text: panel.textContent)
        defer { editor.close() }
        FilePreviewTextEditor<FilePreviewPanel>.bindChangeMarkers(on: editor.scrollView, panel: panel)
        let overlay = try #require(FilePreviewEditorChromeOverlay.installed(in: editor.textView))

        // "TWO\n" is line 2 (modified: green tint, with the old "two" in a
        // red gap above it); "new\n" is line 4 (added: green tint only).
        #expect(overlay.changedLineRanges == [NSRange(location: 4, length: 4), NSRange(location: 14, length: 4)])
        #expect(overlay.deletedLineBlocks == [.init(offset: 4, baseStart: 2, lines: ["two"])])
        let ranges = gutter.changeRanges()
        #expect(ranges.changed == overlay.changedLineRanges)
        #expect(ranges.deleted == overlay.deletedLineBlocks)

        // The gap is paragraph spacing on line 2: one row for one old line,
        // reserved above the used rect, and nothing is added to the text.
        let layoutManager = try #require(editor.textView.layoutManager)
        layoutManager.ensureLayout(for: editor.textView.textContainer!)
        let rowHeight = layoutManager.defaultLineHeight(for: editor.textView.font!)
        let glyph = layoutManager.glyphIndexForCharacter(at: 4)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        #expect(abs((used.minY - fragment.minY) - rowHeight) < 0.5)
        #expect(editor.textView.string == Self.edited)

        // Lines deleted after the last line get their gap below it, and the
        // earlier gap is cleared.
        panel.updateTextContent("one\ntwo\n")
        await panel.awaitChangeTracking()
        editor.textView.string = panel.textContent
        gutter.reloadLineIndex(from: panel.textContent, textFont: editor.textView.font)
        gutter.changeHunks = panel.changeHunks
        #expect(overlay.changedLineRanges.isEmpty)
        #expect(overlay.deletedLineBlocks == [.init(offset: 8, baseStart: 3, lines: ["three", "four"])])
        layoutManager.ensureLayout(for: editor.textView.textContainer!)
        let lastGlyph = layoutManager.numberOfGlyphs - 1
        let lastFragment = layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
        let lastUsed = layoutManager.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
        #expect(abs((lastFragment.maxY - lastUsed.maxY) - 2 * rowHeight) < 0.5)
        let secondGlyph = layoutManager.glyphIndexForCharacter(at: 4)
        let secondFragment = layoutManager.lineFragmentRect(forGlyphAt: secondGlyph, effectiveRange: nil)
        let secondUsed = layoutManager.lineFragmentUsedRect(forGlyphAt: secondGlyph, effectiveRange: nil)
        #expect(abs(secondUsed.minY - secondFragment.minY) < 0.5)
    }

    @Test("A marker click reverts through the bound panel")
    func markerLookupThroughTheGutter() async throws {
        let panel = try await makePanel(contents: Self.edited)
        let (editor, gutter) = makeGutterEditor(text: panel.textContent)
        defer { editor.close() }
        FilePreviewTextEditor<FilePreviewPanel>.bindChangeMarkers(on: editor.scrollView, panel: panel)
        panel.attachTextView(editor.textView)
        editor.textView.delegate = nil

        #expect(gutter.markerHunk(forLine: 1) == nil)
        #expect(gutter.markerHunk(forLine: 2)?.kind == .modified)
        let added = try #require(gutter.markerHunk(forLine: 4))
        #expect(added.kind == .added)
        // A right-click on a changed line's number offers that hunk; an
        // unchanged line offers nothing.
        // The ghost gap above line 2 changed the layout; a click in the app
        // always follows a display pass, so lay out before hit-testing.
        editor.textView.layoutManager?.ensureLayout(for: editor.textView.textContainer!)
        #expect(gutter.revertMenuHunk(atGutterPoint: gutterPoint(forLine: 4, in: gutter, textView: editor.textView)) == added)
        #expect(gutter.revertMenuHunk(atGutterPoint: gutterPoint(forLine: 1, in: gutter, textView: editor.textView)) == nil)
        gutter.onRevertHunk?(added)
        #expect(editor.textView.string == "one\nTWO\nthree\nfour\n")
    }
}
