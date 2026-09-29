import AppKit
import CmuxSettings

extension SavingTextView {
    /// Editor commands that are rebindable cmux shortcuts and dispatched by
    /// the editor itself. Each one runs through
    /// `performFilePreviewEditorAction(_:)`, the path the palette and the
    /// app-level shortcut router share. `.findAndReplace` is an application
    /// shortcut: `AppDelegate.performFindAndReplaceShortcut` routes it to the
    /// focused editor before any key equivalent reaches this view.
    static let filePreviewEditingShortcutActions: [KeyboardShortcutSettings.Action] = [
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
        let visible = visibleRect
        guard let rect = filePreviewRect(for: range), visible.height > rect.height else {
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
        guard var rect = filePreviewRect(for: NSRange(location: selectedRange().location, length: 0)) else {
            return visibleRect
        }
        if rect.width < 1 { rect.size.width = 1 }
        if rect.height < 1 { rect.size.height = font?.pointSize ?? 13 }
        return visibleRect.intersects(rect) ? rect : visibleRect
    }

    /// The bounding rect of `range` in view coordinates, or `nil` without a
    /// TextKit 1 layout stack.
    private func filePreviewRect(for range: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    // MARK: Editing model

    /// Indentation detected from the buffer with the editor's tab width,
    /// cached until the text storage's characters or the tab width change.
    var filePreviewIndentation: FilePreviewIndentation {
        let tabWidth = appliedFilePreviewTabWidth ?? Self.fallbackEditorSettings.tabWidth
        let editCount = filePreviewTextEditCount
        if let cached = cachedFilePreviewIndentation,
           cached.editCount == editCount, cached.tabWidth == tabWidth {
            return cached.indentation
        }
        let detected = FilePreviewIndentation.detect(in: string, tabWidth: tabWidth)
        cachedFilePreviewIndentation = (editCount, tabWidth, detected)
        return detected
    }

    /// The buffer with its indentation resolved lazily, so only Return, Tab,
    /// and Shift-Tab pay for detection (and only on a cache miss).
    var filePreviewTextEditing: FilePreviewTextEditing {
        FilePreviewTextEditing(text: string, indentation: self.filePreviewIndentation)
    }

    /// Computes an edit against the current text and single selection, then
    /// applies it. False when the editor is read-only, is composing marked
    /// text, has several selections, or the command returns nothing.
    @discardableResult
    func applyFilePreviewEdit(
        _ command: (FilePreviewTextEditing, NSRange) -> FilePreviewTextEditResult?
    ) -> Bool {
        guard isEditable, !hasMarkedText(), selectedRanges.count == 1 else { return false }
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

    // MARK: Completion

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
    /// Shows the find bar, or its replace variant for an editable view, and
    /// makes this view first responder so typing lands in the search field.
    /// Returns `false` when the view is not in a window. Shared by the
    /// editor's own command, the app-level Find and Replace shortcut, and
    /// `FilePreviewTextEditingPanel.startTextFind(replace:)`.
    @discardableResult
    func showFilePreviewFindInterface(replace: Bool) -> Bool {
        guard let window else { return false }
        if window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
        performFilePreviewTextFinderAction(replace && isEditable ? .showReplaceInterface : .showFindInterface)
        return enclosingScrollView?.isFindBarVisible ?? false
    }

    /// Sends one `NSTextFinder.Action` the way the Edit > Find menu does.
    func performFilePreviewTextFinderAction(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        performTextFinderAction(sender)
    }
}

/// Counts character edits on an `NSTextStorage` so caches keyed on the
/// buffer's contents (indentation detection) can tell when it changed,
/// whatever path edited it: typing, undo, the find bar, or a panel reload
/// assigning `string`. Attribute-only passes (fonts, highlighting) do not
/// count. Removes its observer when the owning view releases it.
final class FilePreviewTextStorageEditCounter {
    private(set) var count = 0
    private let notificationCenter: NotificationCenter
    private var observer: (any NSObjectProtocol)?

    init(storage: NSTextStorage, notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        observer = notificationCenter.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: storage,
            queue: nil
        ) { [weak self] notification in
            guard let storage = notification.object as? NSTextStorage,
                  storage.editedMask.contains(.editedCharacters) else { return }
            self?.count += 1
        }
    }

    deinit {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
    }
}

/// Counts shortcut-settings changes so each editor rebuilds its cached
/// shortcut candidates only after one, instead of on every key equivalent.
/// Both the cmux shortcut change notification (Settings, `cmux.json`
/// reloads, `resetAll`) and `UserDefaults` writes bump it; posts arrive on
/// whichever thread wrote, so the counter is locked.
final class SavingTextViewShortcutGeneration: @unchecked Sendable {
    static let shared = SavingTextViewShortcutGeneration()

    private let lock = NSLock()
    private var value = 0
    private var observers: [any NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter = .default) {
        for name in [KeyboardShortcutSettings.didChangeNotification, UserDefaults.didChangeNotification] {
            observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.bump()
            })
        }
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    private func bump() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}
