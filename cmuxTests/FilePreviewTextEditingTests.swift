import AppKit
import Carbon.HIToolbox
import CmuxSyntaxHighlighting
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The file editor's line-editing commands are pure functions over
/// `(text, selection)`; these tests pin their edits and selections, then
/// check the text view applies them as one undoable change and routes the
/// configured shortcuts to them.
@MainActor
@Suite("File editor editing commands", .serialized)
struct FilePreviewTextEditingTests {
    private let spaces = FilePreviewIndentation(usesTabs: false, width: 4)
    private let tabs = FilePreviewIndentation(usesTabs: true, width: 4)

    private func editing(_ text: String, _ indentation: FilePreviewIndentation? = nil) -> FilePreviewTextEditing {
        FilePreviewTextEditing(text: text, indentation: indentation ?? spaces)
    }

    private func apply(_ result: FilePreviewTextEditResult, to text: String) -> String {
        let mutable = NSMutableString(string: text)
        for edit in result.edits.sorted(by: { $0.range.location > $1.range.location }) {
            mutable.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return mutable as String
    }

    // MARK: Indentation detection

    @Test("indentation follows the first indented line, skipping blank ones")
    func indentationDetection() {
        #expect(FilePreviewIndentation.detect(in: "a\n\tb\n  c", tabWidth: 4) == tabs)
        #expect(FilePreviewIndentation.detect(in: "a\n  b\n\tc", tabWidth: 2) == FilePreviewIndentation(usesTabs: false, width: 2))
        #expect(FilePreviewIndentation.detect(in: "a\n   \n\tb", tabWidth: 4) == tabs, "whitespace-only lines do not count")
        #expect(FilePreviewIndentation.detect(in: "flat\nfile", tabWidth: 8) == FilePreviewIndentation(usesTabs: false, width: 8))
        #expect(FilePreviewIndentation.detect(in: "", tabWidth: 0).width == 1)
        #expect(FilePreviewIndentation(usesTabs: true, width: 4).unit == "\t")
        #expect(FilePreviewIndentation(usesTabs: false, width: 3).unit == "   ")
    }

    @Test("indentation detection stops at the line and scalar budgets")
    func indentationDetectionBudgets() {
        let manyLines = String(repeating: "x\n", count: FilePreviewIndentation.detectionLineLimit) + "\tb"
        #expect(FilePreviewIndentation.detect(in: manyLines, tabWidth: 4) == spaces)

        let longLine = String(repeating: "x", count: FilePreviewIndentation.detectionScalarLimit)
        #expect(FilePreviewIndentation.detect(in: longLine + "\n\tb", tabWidth: 4) == spaces,
                "a tab-indented line past the scalar budget is never reached")
        let withinBudget = String(repeating: "x", count: FilePreviewIndentation.detectionScalarLimit - 3)
        #expect(FilePreviewIndentation.detect(in: withinBudget + "\n\tb", tabWidth: 4) == tabs)
    }

    @Test("only Return, Tab, and Shift-Tab read the indentation")
    func indentationIsReadLazily() {
        var detections = 0
        func counted() -> FilePreviewIndentation {
            detections += 1
            return spaces
        }
        let text = "a{\nb\n"
        let editing = FilePreviewTextEditing(text: text, indentation: counted())
        _ = editing.toggleLineComment(in: NSRange(location: 0, length: 0), token: "#")
        _ = editing.moveLines(in: NSRange(location: 0, length: 0), up: false)
        _ = editing.duplicateLines(in: NSRange(location: 0, length: 0))
        _ = editing.deleteLines(in: NSRange(location: 0, length: 0))
        _ = editing.lineBlockRange(for: NSRange(location: 0, length: 4))
        #expect(detections == 0)

        _ = editing.newlineInsertion(at: NSRange(location: 2, length: 0))
        #expect(detections == 1)
        _ = editing.tabInsertion(at: NSRange(location: 0, length: 0))
        #expect(detections == 2)
        _ = editing.tabInsertion(at: NSRange(location: 0, length: 4))
        #expect(detections == 3, "indenting a block reads the unit once")
        _ = editing.outdentLines(in: NSRange(location: 0, length: 4))
        #expect(detections == 4, "outdenting a block reads the width once")
    }

    @Test("the editor caches detected indentation until the buffer or tab width changes")
    func editorCachesIndentation() {
        let textView = SavingTextView.makeFilePreviewTextView()
        textView.applyFilePreviewTabWidth(4)
        textView.string = "\ta"
        let afterFirstAssignment = textView.filePreviewTextEditCount
        #expect(afterFirstAssignment > 0)
        #expect(textView.filePreviewIndentation == tabs)
        #expect(textView.cachedFilePreviewIndentation?.editCount == afterFirstAssignment)
        #expect(textView.filePreviewIndentation == tabs)
        #expect(textView.cachedFilePreviewIndentation?.editCount == afterFirstAssignment, "a repeat read is a cache hit")

        textView.string = "  a"
        #expect(textView.filePreviewTextEditCount > afterFirstAssignment, "assigning the string is a character edit")
        #expect(textView.filePreviewIndentation == spaces)

        let beforeTyping = textView.filePreviewTextEditCount
        textView.setSelectedRange(NSRange(location: 0, length: 3))
        textView.insertText("\tb", replacementRange: NSRange(location: 0, length: 3))
        #expect(textView.filePreviewTextEditCount > beforeTyping, "typing is a character edit")
        #expect(textView.filePreviewIndentation == tabs)

        let beforeRestyle = textView.filePreviewTextEditCount
        textView.applyCurrentPreviewFont()
        #expect(textView.filePreviewTextEditCount == beforeRestyle, "attribute passes are not edits")

        textView.applyFilePreviewTabWidth(2)
        #expect(textView.filePreviewIndentation == FilePreviewIndentation(usesTabs: true, width: 2))
    }

    // MARK: Return

    @Test("Return copies the line's indentation and deepens after block openers")
    func newlineAutoIndent() {
        let text = "  foo {\n"
        let result = editing(text).newlineInsertion(at: NSRange(location: 7, length: 0))
        #expect(result.edits == [FilePreviewTextEdit(range: NSRange(location: 7, length: 0), replacement: "\n      ")])
        #expect(result.selection == NSRange(location: 14, length: 0))
        #expect(apply(result, to: text) == "  foo {\n      \n")

        let plain = editing("\tbar\n", tabs).newlineInsertion(at: NSRange(location: 4, length: 0))
        #expect(plain.edits.first?.replacement == "\n\t")

        for opener in ["(", "[", ":"] {
            let line = "    x" + opener + "  "
            let deeper = editing(line, spaces).newlineInsertion(at: NSRange(location: (line as NSString).length, length: 0))
            #expect(deeper.edits.first?.replacement == "\n        ", Comment(rawValue: opener))
        }

        let closed = editing("  f(a)").newlineInsertion(at: NSRange(location: 6, length: 0))
        #expect(closed.edits.first?.replacement == "\n  ", "a closed call does not indent")

        let insideIndent = editing("    x").newlineInsertion(at: NSRange(location: 2, length: 0))
        #expect(insideIndent.edits.first?.replacement == "\n  ", "only the whitespace before the caret is copied")

        let replacingSelection = editing("ab{cd}").newlineInsertion(at: NSRange(location: 3, length: 2))
        #expect(apply(replacingSelection, to: "ab{cd}") == "ab{\n    }")
        #expect(replacingSelection.selection == NSRange(location: 8, length: 0))
    }

    // MARK: Tab and Shift-Tab

    @Test("Tab inserts an indentation unit for a caret and indents lines for a multi-line selection")
    func tabInsertion() {
        let toStop = editing("ab").tabInsertion(at: NSRange(location: 2, length: 0))
        #expect(toStop.edits == [FilePreviewTextEdit(range: NSRange(location: 2, length: 0), replacement: "  ")])
        #expect(toStop.selection == NSRange(location: 4, length: 0))

        let tab = editing("ab", tabs).tabInsertion(at: NSRange(location: 1, length: 0))
        #expect(tab.edits.first?.replacement == "\t")

        let withinLine = editing("hello world").tabInsertion(at: NSRange(location: 6, length: 5))
        #expect(apply(withinLine, to: "hello world") == "hello   ")

        let text = "one\n\ntwo\nthree"
        let block = editing(text).tabInsertion(at: NSRange(location: 1, length: 8))
        #expect(apply(block, to: text) == "    one\n\n    two\nthree", "blank lines stay empty")
        #expect(block.selection == NSRange(location: 5, length: 12))
    }

    @Test("Shift-Tab removes one indentation unit from every selected line")
    func outdent() {
        let text = "    a\n\tb\n  c\nd\n"
        let result = editing(text).outdentLines(in: NSRange(location: 0, length: (text as NSString).length))
        #expect(apply(result, to: text) == "a\nb\nc\nd\n")
        #expect(result.selection == NSRange(location: 0, length: 8))

        let caret = editing("    a").outdentLines(in: NSRange(location: 2, length: 0))
        #expect(caret.selection == NSRange(location: 0, length: 0), "a caret inside the removed whitespace clamps to the line start")
        let caretAfter = editing("    a").outdentLines(in: NSRange(location: 5, length: 0))
        #expect(caretAfter.selection == NSRange(location: 1, length: 0))
    }

    @Test("a selection ending at a line start leaves that line alone")
    func lineBlockExcludesTrailingLineStart() {
        let text = "a\nb\nc"
        let block = editing(text).lineBlockRange(for: NSRange(location: 0, length: 2))
        #expect(block == NSRange(location: 0, length: 2))
        #expect(editing(text).lineBlockRange(for: NSRange(location: 4, length: 0)) == NSRange(location: 4, length: 1))
        #expect(editing("a\n").lineBlockRange(for: NSRange(location: 2, length: 0)) == NSRange(location: 2, length: 0))
    }

    // MARK: Comments

    @Test("toggle line comment comments at the shallowest indent and uncomments when every line is commented")
    func toggleLineComment() {
        let text = "  a\n    b\n\n  c\n"
        let commented = editing(text).toggleLineComment(in: NSRange(location: 0, length: 14), token: "//")
        #expect(apply(commented, to: text) == "  // a\n  //   b\n\n  // c\n")
        #expect(commented.selection == NSRange(location: 0, length: 23))

        let all = "  // a\n  //   b\n\n  // c\n"
        let uncommented = editing(all).toggleLineComment(in: NSRange(location: 0, length: 23), token: "//")
        #expect(apply(uncommented, to: all) == text)

        let mixed = "# a\nb\n"
        let mixedResult = editing(mixed).toggleLineComment(in: NSRange(location: 0, length: 6), token: "#")
        #expect(apply(mixedResult, to: mixed) == "# # a\n# b\n", "one uncommented line comments the whole block")

        let caret = editing("let x = 1").toggleLineComment(in: NSRange(location: 4, length: 0), token: "//")
        #expect(apply(caret, to: "let x = 1") == "// let x = 1")
        #expect(caret.selection == NSRange(location: 7, length: 0))

        let blank = editing("").toggleLineComment(in: NSRange(location: 0, length: 0), token: "--")
        #expect(apply(blank, to: "") == "-- ")
        #expect(blank.selection == NSRange(location: 3, length: 0))

        let noSpace = editing("//x").toggleLineComment(in: NSRange(location: 0, length: 0), token: "//")
        #expect(apply(noSpace, to: "//x") == "x")
    }

    @Test("comment tokens follow the highlighter language with file-name fallbacks")
    func commentTokens() {
        let expectations: [(String?, String, String?)] = [
            ("bash", "run.sh", "#"), ("python", "a.py", "#"), ("ruby", "a.rb", "#"), ("yaml", "a.yml", "#"),
            ("elixir", "a.ex", "#"),
            ("swift", "a.swift", "//"), ("typescript", "a.ts", "//"), ("javascript", "a.js", "//"),
            ("rust", "a.rs", "//"), ("go", "a.go", "//"), ("kotlin", "a.kt", "//"), ("java", "a.java", "//"),
            ("csharp", "a.cs", "//"), ("c", "a.h", "//"), ("cpp", "a.cc", "//"), ("objectivec", "a.m", "//"),
            ("sql", "a.sql", "--"), ("ini", "a.ini", ";"), ("ini", "Cargo.toml", "#"), ("erlang", "a.erl", "%"),
            (nil, "Makefile", "#"), (nil, "Dockerfile", "#"), (nil, "dockerfile.dev", "#"), (nil, ".gitignore", "#"),
            (nil, ".env.local", "#"),
            (nil, "notes.txt", nil), ("json", "a.json", nil), ("markdown", "a.md", nil), ("xml", "a.html", nil),
            ("css", "a.css", nil),
        ]
        for (language, fileName, token) in expectations {
            #expect(FilePreviewLineCommentToken(language: language, fileName: fileName).token == token, "\(fileName)")
        }
        #expect(FilePreviewTextEditor<FilePreviewPanel>.lineCommentToken(forFilePath: "/tmp/src/main.rs").token == "//")
        #expect(FilePreviewTextEditor<FilePreviewPanel>.lineCommentToken(forFilePath: "/tmp/Makefile").token == "#")
        #expect(FilePreviewTextEditor<FilePreviewPanel>.lineCommentToken(forFilePath: "/tmp/README.md").token == nil)
    }

    @Test("every comment-token language is an id the highlighter catalog resolves")
    func commentTokenLanguagesComeFromTheCatalog() {
        let catalog = LanguageCatalog()
        let probeExtensions = [
            "swift", "ts", "js", "py", "json", "md", "go", "rs", "rb", "ex", "erl", "java", "kt", "cs",
            "c", "cpp", "m", "sh", "yml", "toml", "ini", "css", "html", "sql",
        ]
        let catalogLanguages = Set(probeExtensions.compactMap { catalog.language(forExtension: $0) })
        #expect(!catalogLanguages.isEmpty)
        for language in FilePreviewLineCommentToken.tokensByLanguage.keys.sorted() {
            #expect(catalogLanguages.contains(language), "\(language) is not a LanguageCatalog id")
        }
    }

    // MARK: Move, duplicate, delete

    @Test("move line swaps with the neighbor and carries the selection")
    func moveLines() throws {
        let text = "a\nb\nc"
        let down = try #require(editing(text).moveLines(in: NSRange(location: 0, length: 1), up: false))
        #expect(apply(down, to: text) == "b\na\nc")
        #expect(down.selection == NSRange(location: 2, length: 1))

        let up = try #require(editing(text).moveLines(in: NSRange(location: 4, length: 0), up: true))
        #expect(apply(up, to: text) == "a\nc\nb")
        #expect(up.selection == NSRange(location: 2, length: 0))

        let downToLast = try #require(editing(text).moveLines(in: NSRange(location: 2, length: 0), up: false))
        #expect(apply(downToLast, to: text) == "a\nc\nb")
        #expect(downToLast.selection == NSRange(location: 4, length: 0))

        let twoLines = try #require(editing("a\nb\nc\nd\n").moveLines(in: NSRange(location: 2, length: 3), up: false))
        #expect(apply(twoLines, to: "a\nb\nc\nd\n") == "a\nd\nb\nc\n")
        #expect(twoLines.selection == NSRange(location: 4, length: 3))

        #expect(editing(text).moveLines(in: NSRange(location: 0, length: 0), up: true) == nil)
        #expect(editing(text).moveLines(in: NSRange(location: 4, length: 1), up: false) == nil)
        #expect(editing("a\n").moveLines(in: NSRange(location: 2, length: 0), up: false) == nil)
    }

    @Test("duplicate line inserts the copy below and selects it")
    func duplicateLines() {
        let text = "a\nb"
        let first = editing(text).duplicateLines(in: NSRange(location: 0, length: 0))
        #expect(apply(first, to: text) == "a\na\nb")
        #expect(first.selection == NSRange(location: 2, length: 0))

        let last = editing(text).duplicateLines(in: NSRange(location: 3, length: 0))
        #expect(apply(last, to: text) == "a\nb\nb")
        #expect(last.selection == NSRange(location: 5, length: 0))

        let block = editing("a\nb\nc").duplicateLines(in: NSRange(location: 0, length: 3))
        #expect(apply(block, to: "a\nb\nc") == "a\nb\na\nb\nc")
        #expect(block.selection == NSRange(location: 4, length: 3))
    }

    @Test("delete line removes the block and keeps the caret column")
    func deleteLines() {
        let text = "one\ntwo\nthree"
        let middle = editing(text).deleteLines(in: NSRange(location: 6, length: 0))
        #expect(apply(middle, to: text) == "one\nthree")
        #expect(middle.selection == NSRange(location: 6, length: 0))

        let last = editing(text).deleteLines(in: NSRange(location: 12, length: 0))
        #expect(apply(last, to: text) == "one\ntwo")
        #expect(last.selection == NSRange(location: 7, length: 0), "column clamps to the previous line")

        let only = editing("solo").deleteLines(in: NSRange(location: 2, length: 0))
        #expect(apply(only, to: "solo") == "")
        #expect(only.selection == NSRange(location: 0, length: 0))

        let block = editing(text).deleteLines(in: NSRange(location: 1, length: 4))
        #expect(apply(block, to: text) == "three")
        #expect(block.selection == NSRange(location: 1, length: 0))
    }

    // MARK: Go to line

    @Test("go-to-line parsing accepts line and line:column and rejects the rest")
    func goToLineParsing() {
        #expect(FilePreviewLineLocator.parse(" 12 ") == FilePreviewLineLocator.Target(line: 12, column: nil))
        #expect(FilePreviewLineLocator.parse("12:5") == FilePreviewLineLocator.Target(line: 12, column: 5))
        #expect(FilePreviewLineLocator.parse("12,5") == FilePreviewLineLocator.Target(line: 12, column: 5))
        #expect(FilePreviewLineLocator.parse("12:") == FilePreviewLineLocator.Target(line: 12, column: nil))
        #expect(FilePreviewLineLocator.parse("0") == nil)
        #expect(FilePreviewLineLocator.parse("abc") == nil)
        #expect(FilePreviewLineLocator.parse("3:x") == nil)
        #expect(FilePreviewLineLocator.parse("") == nil)
    }

    @Test("go-to-line ranges clamp to the buffer")
    func goToLineRanges() {
        let locator = FilePreviewLineLocator(text: "one\ntwo\n\nfour")
        #expect(locator.lineCount == 4)
        #expect(locator.range(line: 2, column: nil) == NSRange(location: 4, length: 3))
        #expect(locator.range(line: 2, column: 2) == NSRange(location: 5, length: 0))
        #expect(locator.range(line: 2, column: 99) == NSRange(location: 7, length: 0))
        #expect(locator.range(line: 3, column: nil) == NSRange(location: 8, length: 0))
        #expect(locator.range(line: 99, column: nil) == NSRange(location: 9, length: 4))
        #expect(locator.range(line: 0, column: nil) == NSRange(location: 0, length: 3))
        #expect(locator.lineNumber(at: 0) == 1)
        #expect(locator.lineNumber(at: 4) == 2)
        #expect(locator.lineNumber(at: 8) == 3)
        #expect(locator.lineNumber(at: 13) == 4)
        #expect(locator.lineNumber(at: 99) == 4)
        #expect(FilePreviewLineLocator(text: "").range(line: 5, column: 5) == NSRange(location: 0, length: 0))
        #expect(FilePreviewLineLocator(text: "").lineCount == 1)
        #expect(FilePreviewLineLocator(text: "a\n").lineCount == 2)
        #expect(FilePreviewLineLocator(text: "a\n").lineNumber(at: 2) == 2)
        #expect(FilePreviewLineLocator(text: "a\n").range(line: 2, column: nil) == NSRange(location: 2, length: 0))
        #expect(FilePreviewLineLocator(text: "a\r\nb").range(line: 2, column: nil) == NSRange(location: 3, length: 1))
    }

    // MARK: Completion

    @Test("word completion offers distinct buffer identifiers that extend the partial word")
    func wordCompletion() {
        let text = "alpha alphabet beta al_pha alpha Alpine ab a1234 al"
        let completion = FilePreviewWordCompletion(text: text)
        #expect(completion.completions(forPartialWord: "al") == ["al_pha", "alpha", "alphabet", "Alpine"])
        #expect(completion.completions(forPartialWord: "alpha") == ["alphabet"], "the partial word itself is excluded")
        #expect(completion.completions(forPartialWord: "zz") == [])
        #expect(completion.completions(forPartialWord: "a1") == ["a1234"])
        #expect(completion.completions(forPartialWord: "") == ["a1234", "al_pha", "alpha", "alphabet", "Alpine", "beta"])
        #expect(completion.completions(forPartialWord: "AL") == ["al_pha", "alpha", "alphabet", "Alpine"], "matching ignores case")
        #expect(FilePreviewWordCompletion.partialWordRange(in: "foo bar_2", endingAt: 9) == NSRange(location: 4, length: 5))
        #expect(FilePreviewWordCompletion.partialWordRange(in: "foo ", endingAt: 4) == NSRange(location: 4, length: 0))

        let accented = FilePreviewWordCompletion(text: "café cafés caf CAFÉ-bar naïve")
        #expect(accented.completions(forPartialWord: "caf") == ["CAFÉ", "café", "cafés"])
        #expect(accented.completions(forPartialWord: "na") == ["naïve"])
        #expect(FilePreviewWordCompletion.isIdentifierScalar("é"))
        #expect(!FilePreviewWordCompletion.isIdentifierScalar("-"))
    }

    // MARK: Text view integration

    @Test("editor commands apply through the text view as one undoable change")
    func editorAppliesEditsWithUndo() throws {
        let editor = makeWindowedEditor()
        defer { editor.close() }
        let textView = editor.textView
        textView.string = "let a = 1\nlet b = 2\n"
        editor.window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        let undo = try #require(textView.undoManager)

        #expect(textView.performFilePreviewEditorAction(.duplicateLine))
        #expect(textView.string == "let a = 1\nlet a = 1\nlet b = 2\n")
        #expect(textView.selectedRange() == NSRange(location: 14, length: 0))
        #expect(undo.canUndo)
        undo.undo()
        #expect(textView.string == "let a = 1\nlet b = 2\n")

        textView.setSelectedRange(NSRange(location: 4, length: 0))
        #expect(textView.performFilePreviewEditorAction(.moveLineDown))
        #expect(textView.string == "let b = 2\nlet a = 1\n")
        #expect(textView.selectedRange() == NSRange(location: 14, length: 0))
        #expect(!textView.performFilePreviewEditorAction(.moveLineDown), "already the last line")

        #expect(textView.performFilePreviewEditorAction(.deleteLine))
        #expect(textView.string == "let b = 2\n")

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.filePreviewLineCommentToken = FilePreviewLineCommentToken(language: "swift")
        #expect(textView.performFilePreviewEditorAction(.toggleLineComment))
        #expect(textView.string == "// let b = 2\n")
        textView.filePreviewLineCommentToken = FilePreviewLineCommentToken(language: nil)
        #expect(!textView.performFilePreviewEditorAction(.toggleLineComment), "unknown language is a no-op")
        #expect(textView.string == "// let b = 2\n")

        // Without a run loop the move, delete, and comment share one event
        // undo group, so a single undo reverts all three to the original text.
        undo.undo()
        #expect(textView.string == "let a = 1\nlet b = 2\n")
        #expect(!undo.canUndo)

        textView.isEditable = false
        #expect(!textView.performFilePreviewEditorAction(.deleteLine))
        #expect(!textView.performFilePreviewEditorAction(.completeWord))
    }

    @Test("Return, Tab, and Shift-Tab use the file's indentation")
    func responderKeysUseIndentation() {
        let textView = SavingTextView.makeFilePreviewTextView()
        textView.applyFilePreviewTabWidth(2)
        textView.string = "if x {"
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        textView.insertNewline(nil)
        #expect(textView.string == "if x {\n  ")
        #expect(textView.selectedRange() == NSRange(location: 9, length: 0))

        textView.insertTab(nil)
        #expect(textView.string == "if x {\n    ")
        textView.insertBacktab(nil)
        #expect(textView.string == "if x {\n  ")

        textView.string = "\ta\nb"
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        textView.insertTab(nil)
        #expect(textView.string == "\t\ta\n\tb", "a tab-indented file indents with tabs")
        #expect(textView.selectedRange() == NSRange(location: 0, length: 6))
    }

    @Test("editing commands leave marked text to the input method")
    func markedTextOwnsEditingKeys() {
        let textView = SavingTextView.makeFilePreviewTextView()
        textView.filePreviewLineCommentToken = FilePreviewLineCommentToken(language: "swift")
        textView.string = "abc"
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.hasMarkedText())
        #expect(!textView.applyFilePreviewEdit({ $0.tabInsertion(at: $1) }))
        #expect(!textView.performFilePreviewEditorAction(.toggleLineComment))
        #expect(!textView.performFilePreviewEditorAction(.duplicateLine))
        #expect(textView.hasMarkedText())
        #expect(textView.string == "abcに")
    }

    @Test("completion popup data comes from the buffer")
    func completionsFromBuffer() {
        let textView = SavingTextView.makeFilePreviewTextView()
        textView.string = "alpha alphabet beta al"
        textView.setSelectedRange(NSRange(location: 22, length: 0))
        let range = textView.rangeForUserCompletion
        #expect(range == NSRange(location: 20, length: 2))
        var index = -1
        let completions = textView.completions(forPartialWordRange: range, indexOfSelectedItem: &index)
        #expect(completions == ["alpha", "alphabet"])
        #expect(index == 0)
    }

    @Test("go to line selects the line, places the caret at a column, and needs a window for the popover")
    func goToLine() {
        let textView = SavingTextView.makeFilePreviewTextView()
        textView.string = "one\ntwo\nthree"
        #expect(textView.goToFilePreviewLine(2))
        #expect(textView.selectedRange() == NSRange(location: 4, length: 3))
        #expect(textView.goToFilePreviewLine(3, column: 3))
        #expect(textView.selectedRange() == NSRange(location: 10, length: 0))
        #expect(!textView.presentFilePreviewGoToLine(), "no window to anchor the popover")
        #expect(!textView.performFilePreviewEditorAction(.goToLine))

        var committed: FilePreviewLineLocator.Target?
        let popover = FilePreviewGoToLinePopover(currentLine: 2) { committed = $0 }
        #expect(!popover.commit("nope"))
        #expect(committed == nil)
        #expect(popover.commit("3:2"))
        #expect(committed == FilePreviewLineLocator.Target(line: 3, column: 2))
    }

    @Test("configured shortcuts reach the editor commands and honor unbinding")
    func shortcutsRouteToCommands() throws {
        try withDefaultShortcutSettings {
            let textView = SavingTextView.makeFilePreviewTextView()
            textView.filePreviewLineCommentToken = FilePreviewLineCommentToken(language: "python")
            textView.string = "a\nb\nc"
            textView.setSelectedRange(NSRange(location: 0, length: 0))

            let comment = try editorKeyEvent("/", flags: .command, code: UInt16(kVK_ANSI_Slash))
            #expect(textView.performKeyEquivalent(with: comment))
            #expect(textView.string == "# a\nb\nc")

            let down = try editorKeyEvent("\u{F701}", flags: .option, code: UInt16(kVK_DownArrow))
            #expect(textView.performKeyEquivalent(with: down))
            #expect(textView.string == "b\n# a\nc")

            let duplicate = try editorKeyEvent("\u{F701}", flags: [.option, .shift], code: UInt16(kVK_DownArrow))
            #expect(textView.performKeyEquivalent(with: duplicate))
            #expect(textView.string == "b\n# a\n# a\nc")

            let up = try editorKeyEvent("\u{F700}", flags: .option, code: UInt16(kVK_UpArrow))
            #expect(textView.performKeyEquivalent(with: up))
            #expect(textView.string == "b\n# a\n# a\nc")
            #expect(textView.selectedRange().location == 4)

            let delete = try editorKeyEvent("k", flags: [.command, .control], code: UInt16(kVK_ANSI_K))
            #expect(textView.performKeyEquivalent(with: delete))
            #expect(textView.string == "b\n# a\nc")

            KeyboardShortcutSettings.setShortcut(.unbound, for: .deleteLine)
            #expect(!textView.performKeyEquivalent(with: delete))
            #expect(textView.string == "b\n# a\nc")

            KeyboardShortcutSettings.setShortcut(
                StoredShortcut(key: "d", command: true, shift: true, option: true, control: true),
                for: .deleteLine
            )
            let rebound = try editorKeyEvent("d", flags: [.command, .shift, .option, .control], code: UInt16(kVK_ANSI_D))
            #expect(textView.performKeyEquivalent(with: rebound))
            #expect(textView.string == "b\nc")
        }
    }

    /// `performKeyEquivalent` runs for every key-down in the editor. The
    /// candidate list is built once per shortcut-settings change; after
    /// that, plain typing never walks the shortcut table and repeated
    /// shortcuts reuse the cached candidates.
    @Test("plain typing skips shortcut lookups and repeated shortcuts reuse the cached candidates")
    func plainKeysSkipShortcutLookups() throws {
        #if DEBUG
        try withDefaultShortcutSettings {
            let textView = SavingTextView.makeFilePreviewTextView()
            textView.filePreviewLineCommentToken = FilePreviewLineCommentToken(language: "swift")
            textView.string = "a"
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            var lookups = 0
            KeyboardShortcutSettings.shortcutLookupObserver = { _ in lookups += 1 }
            defer { KeyboardShortcutSettings.shortcutLookupObserver = nil }

            let comment = try editorKeyEvent("/", flags: .command, code: UInt16(kVK_ANSI_Slash))
            #expect(textView.performKeyEquivalent(with: comment))
            #expect(textView.string == "// a")
            let builtOnce = lookups
            #expect(builtOnce > 0, "the first key event builds the candidates")

            let plain = try editorKeyEvent("x", flags: [], code: UInt16(kVK_ANSI_X))
            let shifted = try editorKeyEvent("X", flags: .shift, code: UInt16(kVK_ANSI_X))
            let newline = try editorKeyEvent("\r", flags: [], code: UInt16(kVK_Return))
            #expect(!textView.performKeyEquivalent(with: plain))
            #expect(!textView.performKeyEquivalent(with: shifted))
            #expect(!textView.performKeyEquivalent(with: newline))
            #expect(lookups == builtOnce, "no Command, Control, or Option: the shortcut table is not consulted")

            #expect(textView.performKeyEquivalent(with: comment))
            #expect(textView.string == "a")
            #expect(lookups == builtOnce, "the second shortcut reuses the cached candidates")

            KeyboardShortcutSettings.setShortcut(.unbound, for: .toggleLineComment)
            #expect(!textView.performKeyEquivalent(with: comment))
            #expect(textView.string == "a")
            #expect(lookups > builtOnce, "a settings change rebuilds the candidates")
            let rebuilt = lookups
            #expect(!textView.performKeyEquivalent(with: plain))
            #expect(lookups == rebuilt)
        }
        #else
        Issue.record("shortcutLookupObserver is only available in DEBUG")
        #endif
    }

    @Test("the new editor defaults stay clear of every other default in an overlapping context")
    func defaultsDoNotCollide() {
        let editorActions: [KeyboardShortcutSettings.Action] = [
            .findAndReplace, .goToLine, .toggleLineComment, .moveLineUp, .moveLineDown,
            .duplicateLine, .deleteLine, .completeWord,
        ]
        for action in editorActions {
            #expect(!action.defaultShortcut.isUnbound, Comment(rawValue: action.rawValue))
            #expect(KeyboardShortcutSettings.settingsVisibleActions.contains(action), Comment(rawValue: action.rawValue))
            for other in KeyboardShortcutSettings.Action.allCases where other != action {
                #expect(
                    !action.conflicts(
                        with: other.defaultShortcut,
                        proposedAction: other,
                        configuredShortcut: action.defaultShortcut
                    ),
                    "\(action.rawValue) vs \(other.rawValue)"
                )
            }
        }
        #expect(KeyboardShortcutSettings.Action.findAndReplace.shortcutContext == .application)
        #expect(!SavingTextView.filePreviewEditingShortcutActions.contains(.findAndReplace),
                "the application shortcut is routed by the AppDelegate, not the editor")
        #expect(KeyboardShortcutSettings.Action.goToLine.shortcutContext == .filePreviewTextEditor)
        #expect(KeyboardShortcutSettings.Action.completeWord.shortcutContext == .filePreviewTextEditor)
    }

    @Test("cmux.json bindings rebind the editor commands")
    func fileConfiguredBinding() throws {
        try withShortcutSettingsFile(
            """
            {"shortcuts":{"bindings":{"toggleLineComment":"cmd+opt+/","goToLine":null}}}
            """
        ) {
            #expect(KeyboardShortcutSettings.shortcut(for: .goToLine).isUnbound)
            let textView = SavingTextView.makeFilePreviewTextView()
            textView.filePreviewLineCommentToken = FilePreviewLineCommentToken(language: "sql")
            textView.string = "select 1"
            let commandSlash = try editorKeyEvent("/", flags: .command, code: UInt16(kVK_ANSI_Slash))
            let commandOptionSlash = try editorKeyEvent("/", flags: [.command, .option], code: UInt16(kVK_ANSI_Slash))
            #expect(!textView.performKeyEquivalent(with: commandSlash))
            #expect(textView.performKeyEquivalent(with: commandOptionSlash))
            #expect(textView.string == "-- select 1")
        }
    }
}
