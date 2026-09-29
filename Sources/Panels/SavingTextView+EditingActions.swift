import AppKit
import CmuxSettings

extension SavingTextView {
    /// Editor commands that are rebindable cmux shortcuts. Each one runs
    /// through `performFilePreviewEditorAction(_:)`, the path the palette and
    /// the app-level shortcut router share.
    static let filePreviewEditingShortcutActions: [KeyboardShortcutSettings.Action] = [
        .findAndReplace,
        .goToLine,
        .toggleLineComment,
        .moveLineUp,
        .moveLineDown,
        .duplicateLine,
        .deleteLine,
        .completeWord,
    ]

    /// Joins the editing commands to the editor's chord dispatcher.
    func filePreviewEditingShortcutCandidates() -> [
        (shortcut: StoredShortcut, isAllowed: (NSEvent) -> Bool, perform: () -> Void)
    ] {
        Self.filePreviewEditingShortcutActions.compactMap { action -> (shortcut: StoredShortcut, isAllowed: (NSEvent) -> Bool, perform: () -> Void)? in
            let shortcut = KeyboardShortcutSettings.shortcut(for: action)
            guard !shortcut.isUnbound else { return nil }
            return (
                shortcut,
                { [weak self] event in
                    self?.filePreviewEditorShortcutWhenClauseAllows(action: action, event: event) ?? false
                },
                { [weak self] in _ = self?.performFilePreviewEditorAction(action) }
            )
        }
    }

    func filePreviewEditorShortcutWhenClauseAllows(action: KeyboardShortcutSettings.Action, event: NSEvent) -> Bool {
        if window != nil, let appDelegate = AppDelegate.shared {
            return appDelegate.shortcutWhenClauseAllows(action: action, event: event)
        }
        return KeyboardShortcutSettings.effectiveWhenClause(for: action)
            .evaluate(Self.filePreviewTextEditorShortcutContext)
    }

    /// Runs one editor command. Returns false when the command does not
    /// apply (unknown language for comments, first line for Move Line Up,
    /// a read-only editor, or an editor with no window for Go to Line).
    @discardableResult
    func performFilePreviewEditorAction(_ action: KeyboardShortcutSettings.Action) -> Bool {
        switch action {
        case .findAndReplace:
            return showFilePreviewFindInterface(replace: true)
        case .goToLine:
            return presentFilePreviewGoToLine()
        case .toggleLineComment:
            guard let token = filePreviewLineCommentToken.token else { return false }
            return applyFilePreviewEdit { $0.toggleLineComment(in: $1, token: token) }
        case .moveLineUp:
            return applyFilePreviewEdit { $0.moveLines(in: $1, up: true) }
        case .moveLineDown:
            return applyFilePreviewEdit { $0.moveLines(in: $1, up: false) }
        case .duplicateLine:
            return applyFilePreviewEdit { $0.duplicateLines(in: $1) }
        case .deleteLine:
            return applyFilePreviewEdit { $0.deleteLines(in: $1) }
        case .completeWord:
            guard isEditable else { return false }
            complete(nil)
            return true
        default:
            return false
        }
    }

    // MARK: Find

    /// Shows the find bar, or its replace variant, and makes this editor
    /// first responder so typing lands in the search field.
    @discardableResult
    func showFilePreviewFindInterface(replace: Bool) -> Bool {
        guard let window else { return false }
        if window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
        performFilePreviewTextFinderAction(replace && isEditable ? .showReplaceInterface : .showFindInterface)
        return enclosingScrollView?.isFindBarVisible ?? false
    }

    // MARK: Go to Line

    /// Opens the Go to Line popover under the caret.
    @discardableResult
    func presentFilePreviewGoToLine() -> Bool {
        guard window != nil else { return false }
        if let existing = filePreviewGoToLinePopover, existing.isShown {
            return true
        }
        let locator = FilePreviewLineLocator(text: string)
        let popover = FilePreviewGoToLinePopover(
            currentLine: locator.lineNumber(at: selectedRange().location)
        ) { [weak self] target in
            _ = self?.goToFilePreviewLine(target.line, column: target.column)
        }
        filePreviewGoToLinePopover = popover
        popover.show(relativeTo: filePreviewCaretAnchorRect(), of: self) { [weak self] in
            guard let self else { return }
            filePreviewGoToLinePopover = nil
            window?.makeFirstResponder(self)
        }
        return true
    }

    /// Selects `line` (or places the caret at `column` on it) and scrolls it
    /// to the middle of the visible area.
    @discardableResult
    func goToFilePreviewLine(_ line: Int, column: Int? = nil) -> Bool {
        let range = FilePreviewLineLocator(text: string).range(line: line, column: column)
        setSelectedRange(range)
        scrollFilePreviewRangeToCenter(range)
        return true
    }

    func scrollFilePreviewRangeToCenter(_ range: NSRange) {
        guard let layoutManager, let textContainer else {
            scrollRangeToVisible(range)
            return
        }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        let visible = visibleRect
        guard visible.height > rect.height else {
            scrollRangeToVisible(range)
            return
        }
        var target = rect
        target.origin.y -= (visible.height - rect.height) / 2
        target.size.height = visible.height
        target.origin.x = visible.origin.x
        target.size.width = max(visible.width, 1)
        scrollToVisible(target)
    }

    private func filePreviewCaretAnchorRect() -> NSRect {
        guard let layoutManager, let textContainer else { return visibleRect }
        let caret = NSRange(location: selectedRange().location, length: 0)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: caret, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        if rect.width < 1 { rect.size.width = 1 }
        if rect.height < 1 { rect.size.height = font?.pointSize ?? 13 }
        return visibleRect.intersects(rect) ? rect : visibleRect
    }

    // MARK: Editing model

    /// Indentation detected from the buffer with the editor's tab width.
    var filePreviewIndentation: FilePreviewIndentation {
        FilePreviewIndentation.detect(
            in: string,
            tabWidth: appliedFilePreviewTabWidth ?? FileEditorCatalogSection().tabWidth.defaultValue
        )
    }

    var filePreviewTextEditing: FilePreviewTextEditing {
        FilePreviewTextEditing(text: string, indentation: filePreviewIndentation)
    }

    /// Computes an edit against the current text and single selection, then
    /// applies it. False when the editor is read-only, has several
    /// selections, or the command returns nothing.
    @discardableResult
    func applyFilePreviewEdit(
        _ command: (FilePreviewTextEditing, NSRange) -> FilePreviewTextEditResult?
    ) -> Bool {
        guard isEditable, selectedRanges.count == 1 else { return false }
        return applyFilePreviewEdit(command(filePreviewTextEditing, selectedRange()))
    }

    /// Applies `result` through `shouldChangeText(inRanges:replacementStrings:)`
    /// and `didChangeText()` so the change is one undoable step.
    @discardableResult
    func applyFilePreviewEdit(_ result: FilePreviewTextEditResult?) -> Bool {
        guard let result, isEditable else { return false }
        let contentLength = (string as NSString).length
        let ordered = result.edits.sorted { $0.range.location < $1.range.location }
        guard ordered.allSatisfy({ NSMaxRange($0.range) <= contentLength }) else { return false }
        if !ordered.isEmpty {
            let ranges = ordered.map { NSValue(range: $0.range) }
            let replacements = ordered.map(\.replacement)
            guard shouldChangeText(inRanges: ranges, replacementStrings: replacements),
                  let storage = textStorage else { return false }
            breakUndoCoalescing()
            let attributes = typingAttributes
            storage.beginEditing()
            for edit in ordered.reversed() {
                storage.replaceCharacters(
                    in: edit.range,
                    with: NSAttributedString(string: edit.replacement, attributes: attributes)
                )
            }
            storage.endEditing()
            didChangeText()
            breakUndoCoalescing()
        }
        let newLength = (string as NSString).length
        let location = min(result.selection.location, newLength)
        let length = min(result.selection.length, newLength - location)
        let selection = NSRange(location: location, length: length)
        setSelectedRange(selection)
        scrollRangeToVisible(selection)
        return true
    }

    // MARK: Responder hooks

    /// Return with auto-indent; false hands the key back to AppKit.
    func handleFilePreviewNewline() -> Bool {
        guard !hasMarkedText() else { return false }
        return applyFilePreviewEdit { $0.newlineInsertion(at: $1) }
    }

    /// Tab: indent the selected lines, or insert one indentation unit.
    func handleFilePreviewTab() -> Bool {
        guard !hasMarkedText() else { return false }
        return applyFilePreviewEdit { $0.tabInsertion(at: $1) }
    }

    /// Shift-Tab: outdent the selected lines.
    func handleFilePreviewBacktab() -> Bool {
        guard !hasMarkedText() else { return false }
        return applyFilePreviewEdit { $0.outdentLines(in: $1) }
    }

    /// Words from the buffer that extend the identifier in `charRange`.
    func filePreviewCompletions(forPartialWordRange charRange: NSRange) -> [String] {
        let content = string as NSString
        guard charRange.location != NSNotFound, NSMaxRange(charRange) <= content.length else { return [] }
        let partial = content.substring(with: charRange)
        return FilePreviewWordCompletion(text: string).completions(forPartialWord: partial)
    }

    /// The identifier ending at the caret, so `_` and digits complete as
    /// part of one word.
    func filePreviewRangeForUserCompletion() -> NSRange {
        FilePreviewWordCompletion.partialWordRange(in: string as NSString, endingAt: selectedRange().location)
    }
}

extension NSTextView {
    /// Sends one `NSTextFinder.Action` the way the Edit > Find menu does.
    func performFilePreviewTextFinderAction(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        performTextFinderAction(sender)
    }
}
