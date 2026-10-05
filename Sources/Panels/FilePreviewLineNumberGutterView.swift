import AppKit
import CmuxFilePreviewCore
import CmuxSyntaxHighlighting

/// TextKit 1 line-number ruler. Draws only fragments that intersect the viewport.
///
/// Fills with the editor surface so numbers sit in the margin instead of on
/// AppKit's default contrasting ruler strip.
///
/// The line index is maintained incrementally from text-storage edit
/// notifications (`NSText.didProcessEditingNotification`) so typing never
/// rescans the whole buffer; a keystroke splices a few line-start offsets
/// instead of walking up to 16 MB of text on the main actor.
///
/// Beyond the numbers, the ruler keeps the diff in view while the file is
/// edited: the working-tree changes against git's index are drawn as
/// markers in a strip at its leading edge (a click on one offers to revert
/// the hunk), a click or drag on the numbers selects whole lines, and a
/// button floats on the selection to hand those lines to the agent prompt.
final class FilePreviewLineNumberGutterView: NSRulerView {
    var tokenTheme: TokenTheme = .dark {
        didSet { needsDisplay = true }
    }
    var editorBackgroundColor: NSColor = .clear {
        didSet { applySurfaceFill() }
    }
    var drawsEditorBackground = true {
        didSet { applySurfaceFill() }
    }
    /// Working-tree changes to mark; nil draws no markers. The overlay in
    /// the text area is kept in step so the changed lines tint there too.
    var changeHunks: FilePreviewChangeHunks? {
        didSet {
            guard changeHunks != oldValue else { return }
            needsDisplay = true
            pushChangeRangesToOverlay()
        }
    }
    /// Reverts one hunk; a click on its marker offers it from a menu.
    var onRevertHunk: ((FilePreviewChangeHunk) -> Void)?
    /// Hands the selected lines (1-based, inclusive) to the agent prompt.
    /// Without it the prompt button never shows.
    var onInsertPromptReference: ((_ startLine: Int, _ endLine: Int) -> Void)? {
        didSet { updatePromptButton() }
    }
    private static let horizontalPadding: CGFloat = 10
    private static let promptButtonSize: CGFloat = 18
    /// The deleted lines shown in gaps, with their base line numbers.
    private var deletedBlocks: [FilePreviewEditorChromeOverlay.DeletedLineBlock] = []
    /// The selected lines during one draw pass, so each number cell can
    /// take the selection colour without re-reading the selection.
    private var selectedLinesForDrawing: ClosedRange<Int>?
    /// Trailing column the prompt button sits in, so it never covers a number.
    static let promptButtonColumnWidth: CGFloat = 24

    private var lineIndex = FilePreviewLineIndex(string: "")
    /// Set when edits were skipped (ruler hidden) and the index must be
    /// rebuilt before its next use.
    private var needsFullRebuild = true
    private var observedStorage: NSTextStorage?
    private var storageObserver: (any NSObjectProtocol)?
    private var clipBoundsObserver: (any NSObjectProtocol)?
    /// The line a gutter drag started on; the selection runs from it.
    private var selectionAnchorLine: Int?
    /// The hunk a marker click opened the menu for, until an item runs.
    private var pendingMenuHunk: FilePreviewChangeHunk?
    private lazy var promptButton: NSButton = makePromptButton()

    override var isOpaque: Bool {
        drawsEditorBackground && editorBackgroundColor.alphaComponent >= 0.999
    }

    override var wantsUpdateLayer: Bool { false }

    override var clientView: NSView? {
        didSet { observeStorage(of: clientView) }
    }

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        clientView = scrollView?.documentView
        ruleThickness = 36
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        wantsLayer = true
        applySurfaceFill()
        observeClipBounds(of: scrollView)
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        if let storageObserver {
            NotificationCenter.default.removeObserver(storageObserver)
        }
        if let clipBoundsObserver {
            NotificationCenter.default.removeObserver(clipBoundsObserver)
        }
    }

    /// Reconciles the index against `string`.
    ///
    /// While storage observation is live, per-edit increments keep the index
    /// exact and this is a no-op scan; a full rebuild happens only after
    /// skipped edits (ruler hidden) or on first attach.
    func reloadLineIndex(from string: String, textFont: NSFont?) {
        if needsFullRebuild || observedStorage == nil {
            lineIndex = FilePreviewLineIndex(string: string)
            needsFullRebuild = false
        }
        updateRuleThickness(for: textFont)
        needsDisplay = true
        pushChangeRangesToOverlay()
    }

    /// Subscribes to the client text view's storage edits.
    private func observeStorage(of view: NSView?) {
        if let storageObserver {
            NotificationCenter.default.removeObserver(storageObserver)
        }
        storageObserver = nil
        observedStorage = nil
        guard let textView = view as? NSTextView,
              let storage = textView.textStorage else {
            needsFullRebuild = true
            return
        }
        observedStorage = storage
        if scrollView?.rulersVisible == true {
            lineIndex = FilePreviewLineIndex(string: textView.string)
            needsFullRebuild = false
        } else {
            // Keep the index lazy while line numbers are disabled. A large
            // hidden preview should not allocate line metadata it cannot draw.
            needsFullRebuild = true
        }
        updateRuleThickness(for: textView.font)
        // `queue: nil` delivers synchronously on the posting (main) thread, so
        // the index is exact before the next layout/draw pass reads it.
        storageObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: storage,
            queue: nil
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.applyStorageEdit(from: notification)
            }
        }
    }

    /// The prompt button sits on a document line, so scrolling moves it.
    private func observeClipBounds(of scrollView: NSScrollView?) {
        if let clipBoundsObserver {
            NotificationCenter.default.removeObserver(clipBoundsObserver)
        }
        clipBoundsObserver = nil
        guard let clipView = scrollView?.contentView else { return }
        clipView.postsBoundsChangedNotifications = true
        clipBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updatePromptButton()
            }
        }
    }

    /// Applies one storage edit to the index. Skips maintenance while the
    /// ruler is hidden (the index is unread then) and flags a rebuild for the
    /// next time it becomes visible.
    private func applyStorageEdit(from notification: Notification) {
        guard scrollView?.rulersVisible == true else {
            needsFullRebuild = true
            return
        }
        guard let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters) else { return }
        let range = storage.editedRange
        let replacement = (storage.string as NSString).substring(with: range)
        lineIndex.applyEdit(
            atUTF16Location: range.location,
            replacingUTF16Length: range.length - storage.changeInLength,
            replacement: replacement
        )
        updateRuleThickness(for: (clientView as? NSTextView)?.font)
        needsDisplay = true
    }

    private func updateRuleThickness(for textFont: NSFont?) {
        let font = labelFont(for: textFont)
        let digits = max(2, String(lineIndex.lineCount).count)
        let labelWidth = (String(repeating: "8", count: digits) as NSString).size(
            withAttributes: [.font: font]
        ).width
        let nextThickness = ceil(labelWidth) + Self.horizontalPadding + Self.promptButtonColumnWidth
        if abs(ruleThickness - nextThickness) > 0.5 {
            ruleThickness = nextThickness
        }
    }

    private func labelFont(for textFont: NSFont?) -> NSFont {
        NSFont.monospacedDigitSystemFont(
            ofSize: max(9, (textFont?.pointSize ?? 13) * 0.78),
            weight: .regular
        )
    }

    private func applySurfaceFill() {
        wantsLayer = true
        layer?.backgroundColor = drawsEditorBackground
            ? editorBackgroundColor.cgColor
            : NSColor.clear.cgColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Do not call super — NSRulerView paints a system control strip
        // that reads as a second background next to the editor.
        if drawsEditorBackground {
            editorBackgroundColor.setFill()
            bounds.fill()
        } else {
            NSColor.clear.setFill()
            bounds.fill()
        }
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let visibleRect = textView.visibleRect
        let glyphQueryRect = visibleRect.offsetBy(
            dx: -textView.textContainerOrigin.x,
            dy: -textView.textContainerOrigin.y
        )
        let glyphRange = layoutManager.glyphRange(forBoundingRect: glyphQueryRect, in: textContainer)
        let font = labelFont(for: textView.font)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        let selected = textView.selectedRange()
        let currentLine = selected.length == 0
            ? lineIndex.lineNumber(containingUTF16Offset: selected.location)
            : nil
        selectedLinesForDrawing = selectedLineRange(in: textView)
        defer { selectedLinesForDrawing = nil }
        let lineCount = lineIndex.lineCount
        var drewTrailingLine = false

        let stringLength = (textView.string as NSString).length
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, usedRect, _, fragmentGlyphRange, _ in
            let characterRange = layoutManager.characterRange(
                forGlyphRange: fragmentGlyphRange,
                actualGlyphRange: nil
            )
            // Paragraph spacing is the gap that holds deleted lines: the
            // fragment rect includes it, the used rect does not. Number the
            // gap with the base lines it shows.
            if usedRect.minY > rect.minY,
               let block = self.deletedBlocks.first(where: { $0.offset == characterRange.location }) {
                self.drawDeletedLines(
                    block,
                    atTextViewY: rect.minY + textView.textContainerOrigin.y,
                    height: usedRect.minY - rect.minY,
                    in: textView,
                    font: font,
                    paragraphStyle: paragraphStyle
                )
            }
            if rect.maxY > usedRect.maxY,
               let block = self.deletedBlocks.first(where: { $0.offset >= stringLength }) {
                self.drawDeletedLines(
                    block,
                    atTextViewY: usedRect.maxY + textView.textContainerOrigin.y,
                    height: rect.maxY - usedRect.maxY,
                    in: textView,
                    font: font,
                    paragraphStyle: paragraphStyle
                )
            }
            let lineNumber = self.lineIndex.lineNumber(
                containingUTF16Offset: characterRange.location
            )
            guard self.lineIndex.offset(forLine: lineNumber) == characterRange.location else {
                return
            }
            self.drawLineNumber(
                lineNumber,
                atTextViewY: usedRect.minY + textView.textContainerOrigin.y,
                height: usedRect.height,
                in: textView,
                font: font,
                paragraphStyle: paragraphStyle,
                currentLine: currentLine
            )
            drewTrailingLine = drewTrailingLine || lineNumber == lineCount
        }

        let string = textView.string as NSString
        if layoutManager.numberOfGlyphs == 0, string.length == 0 {
            // An empty document has a valid logical line but no glyph fragment
            // for TextKit to enumerate. Paint its first line directly without
            // asking `lineFragmentRect` for an invalid glyph.
            self.drawLineNumber(
                1,
                atTextViewY: textView.textContainerOrigin.y,
                height: textView.font?.boundingRectForFont.height ?? 16,
                in: textView,
                font: font,
                paragraphStyle: paragraphStyle,
                currentLine: currentLine
            )
        } else if !drewTrailingLine, Self.endsWithLineBreak(string) {
            // The final empty line after a newline has no glyph of its own.
            // TextKit exposes its actual visual position through the extra
            // line fragment; this remains correct when the preceding logical
            // line wraps into multiple visual fragments.
            let fallbackHeight = max(textView.font?.boundingRectForFont.height ?? 16, 1)
            let extra = layoutManager.extraLineFragmentRect
            let trailingRect: NSRect?
            if Self.isUsableLineRect(extra) {
                trailingRect = extra
            } else if layoutManager.numberOfGlyphs > 0 {
                // A non-contiguous layout may not have populated the extra
                // rect yet. Use the last realized fragment if available; do
                // not force a potentially huge synchronous layout in draw.
                var lastRange = NSRange()
                let lastFragment = layoutManager.lineFragmentRect(
                    forGlyphAt: layoutManager.numberOfGlyphs - 1,
                    effectiveRange: &lastRange,
                    withoutAdditionalLayout: true
                )
                trailingRect = Self.isUsableLineRect(lastFragment)
                    ? NSRect(
                        x: lastFragment.minX,
                        y: lastFragment.maxY,
                        width: lastFragment.width,
                        height: max(lastFragment.height, fallbackHeight)
                    )
                    : nil
            } else {
                trailingRect = nil
            }

            if let trailingRect {
                let y = trailingRect.minY + textView.textContainerOrigin.y
                let viewRect = textView.visibleRect
                let visibleTrailingRect = NSRect(
                    x: viewRect.minX,
                    y: y,
                    width: max(1, viewRect.width),
                    height: max(trailingRect.height, fallbackHeight)
                )
                if NSIntersectsRect(visibleTrailingRect, viewRect) {
                    self.drawLineNumber(
                        lineCount,
                        atTextViewY: y,
                        height: max(trailingRect.height, fallbackHeight),
                        in: textView,
                        font: font,
                        paragraphStyle: paragraphStyle,
                        currentLine: currentLine
                    )
                }
            }
        }
    }

    private static func isUsableLineRect(_ rect: NSRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.height > 0
    }

    private static func endsWithLineBreak(_ string: NSString) -> Bool {
        guard string.length > 0 else { return false }
        let last = string.character(at: string.length - 1)
        return last == 0x0A || last == 0x0D || last == 0x2028 || last == 0x2029
    }

    private func drawLineNumber(
        _ lineNumber: Int,
        atTextViewY y: CGFloat,
        height: CGFloat,
        in textView: NSTextView,
        font: NSFont,
        paragraphStyle: NSParagraphStyle,
        currentLine: Int?
    ) {
        let documentPoint = NSPoint(x: 0, y: y)
        let rulerPoint = convert(documentPoint, from: textView)
        let cellWidth = numberCellWidth
        let cell = NSRect(x: 0, y: rulerPoint.y, width: cellWidth, height: height)
        // A new or changed line wears the diff's green: a tinted cell and a
        // green number.
        let changed = markerHunk(forLine: lineNumber).map { $0.currentCount > 0 } ?? false
        if changed {
            NSColor.systemGreen.withAlphaComponent(0.14).setFill()
            cell.fill()
        }
        // Selected lines select their numbers too, in the selection colour.
        if let selectedLines = selectedLinesForDrawing, selectedLines.contains(lineNumber) {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).setFill()
            cell.fill()
        }
        let labelRect = NSRect(
            x: 4,
            y: rulerPoint.y,
            width: max(0, cellWidth - 8),
            height: max(height, font.capHeight + 4)
        )
        let color: NSColor
        if changed {
            color = .systemGreen
        } else if currentLine == lineNumber {
            color = tokenTheme.gutterCurrentLineColor
        } else {
            color = tokenTheme.gutterDefaultColor
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
        NSString(string: String(lineNumber)).draw(in: labelRect, withAttributes: attributes)
    }

    /// The number cells' width: the ruler less the prompt button's column.
    private var numberCellWidth: CGFloat {
        max(0, ruleThickness - Self.promptButtonColumnWidth)
    }

    /// The diff's red for a gap of deleted lines: a tinted cell carrying
    /// each deleted line's base number in red, row by row.
    private func drawDeletedLines(
        _ block: FilePreviewEditorChromeOverlay.DeletedLineBlock,
        atTextViewY y: CGFloat,
        height: CGFloat,
        in textView: NSTextView,
        font: NSFont,
        paragraphStyle: NSParagraphStyle
    ) {
        let top = convert(NSPoint(x: 0, y: y), from: textView).y
        let cellWidth = numberCellWidth
        NSColor.systemRed.withAlphaComponent(0.14).setFill()
        NSRect(x: 0, y: top, width: cellWidth, height: height).fill()
        let fallbackRow = textView.layoutManager?.defaultLineHeight(for: textView.font ?? font) ?? height
        let rowHeights = FilePreviewEditorChromeOverlay.installed(in: textView)?.ghostRowHeights(for: block)
            ?? Array(repeating: fallbackRow, count: block.lines.count)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.systemRed,
            .paragraphStyle: paragraphStyle
        ]
        var rowY = top
        for (index, rowHeight) in rowHeights.enumerated() {
            let labelRect = NSRect(x: 4, y: rowY, width: max(0, cellWidth - 8), height: max(rowHeight, font.capHeight + 4))
            NSString(string: String(block.baseStart + index)).draw(in: labelRect, withAttributes: attributes)
            rowY += rowHeight
        }
    }

    // MARK: - Change markers

    /// The hunk whose marker sits on `line`: its own lines, or for a deletion
    /// the line it used to precede. A deletion past the last line is drawn
    /// under that line.
    func markerHunk(forLine line: Int) -> FilePreviewChangeHunk? {
        guard let hunks = changeHunks else { return nil }
        if let hunk = hunks.hunk(atCurrentLine: line) { return hunk }
        if line == lineIndex.lineCount,
           let last = hunks.hunks.last,
           last.currentCount == 0,
           last.currentStart == line + 1 {
            return last
        }
        return nil
    }

    /// The same colours as the diff: green on the lines that are new or
    /// The hunk a right-click on `point` offers to revert: the one on that
    /// line, or the one whose deleted lines fill the gap above it.
    func revertMenuHunk(atGutterPoint point: NSPoint) -> FilePreviewChangeHunk? {
        guard let line = lineNumber(atGutterPoint: point) else { return nil }
        return markerHunk(forLine: line)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard onRevertHunk != nil, let hunk = revertMenuHunk(atGutterPoint: point) else {
            super.rightMouseDown(with: event)
            return
        }
        showRevertMenu(for: hunk, with: event)
    }

    /// The text ranges the overlay tints (one per hunk with current lines)
    /// and the deleted lines it shows in gaps (a modification's base lines
    /// are gone too, so it has both).
    func changeRanges() -> (changed: [NSRange], deleted: [FilePreviewEditorChromeOverlay.DeletedLineBlock]) {
        guard let hunks = changeHunks, let textView = clientView as? NSTextView else { return ([], []) }
        let lineCount = lineIndex.lineCount
        let utf16Length = (textView.string as NSString).length
        func lineStart(_ line: Int) -> Int {
            line <= lineCount ? lineIndex.offset(forLine: line) : utf16Length
        }
        var changed: [NSRange] = []
        var deleted: [FilePreviewEditorChromeOverlay.DeletedLineBlock] = []
        for hunk in hunks.hunks {
            let start = lineStart(hunk.currentStart)
            if hunk.currentCount > 0 {
                let end = lineStart(hunk.currentStart + hunk.currentCount)
                changed.append(NSRange(location: start, length: max(0, end - start)))
            }
            if !hunk.baseLines.isEmpty {
                deleted.append(.init(offset: start, baseStart: hunk.baseStart, lines: hunk.baseLines))
            }
        }
        return (changed, deleted)
    }

    private func pushDeletedBlocks(_ blocks: [FilePreviewEditorChromeOverlay.DeletedLineBlock]) {
        if deletedBlocks != blocks {
            deletedBlocks = blocks
            needsDisplay = true
        }
    }

    private func pushChangeRangesToOverlay() {
        guard let textView = clientView as? NSTextView,
              let overlay = FilePreviewEditorChromeOverlay.installed(in: textView) else { return }
        let ranges = changeRanges()
        pushDeletedBlocks(ranges.deleted)
        overlay.changedLineRanges = ranges.changed
        overlay.deletedLineBlocks = ranges.deleted
        // The text may have been replaced under unchanged blocks; the gaps
        // live in its paragraph styles and must be written again.
        overlay.applyGhostGapSpacing()
    }

    private func showRevertMenu(for hunk: FilePreviewChangeHunk, with event: NSEvent) {
        let menu = NSMenu()
        let item = NSMenuItem(
            title: String(localized: "filePreview.revertChange", defaultValue: "Revert Change"),
            action: #selector(revertPendingHunk(_:)),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
        pendingMenuHunk = hunk
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func revertPendingHunk(_ sender: Any?) {
        let hunk = pendingMenuHunk
        pendingMenuHunk = nil
        if let hunk {
            onRevertHunk?(hunk)
        }
    }

    // MARK: - Line selection

    /// The 1-based line under `point` (in the ruler's coordinates); the last
    /// line below the text.
    func lineNumber(atGutterPoint point: NSPoint) -> Int? {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return nil }
        let textPoint = convert(point, to: textView)
        let containerPoint = NSPoint(x: 0, y: textPoint.y - textView.textContainerOrigin.y)
        guard containerPoint.y >= 0 else { return 1 }
        let usedRect = layoutManager.usedRect(for: container)
        if containerPoint.y >= usedRect.maxY {
            return lineIndex.lineCount
        }
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: container)
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return min(lineIndex.lineNumber(containingUTF16Offset: characterIndex), lineIndex.lineCount)
    }

    /// Selects whole lines `anchor` through `line` in either order, with the
    /// line break that closes the last of them when another line follows.
    func selectLines(from anchor: Int, to line: Int, in textView: NSTextView) {
        let lineCount = lineIndex.lineCount
        let first = max(1, min(anchor, line, lineCount))
        let last = max(first, min(lineCount, max(anchor, line)))
        let start = lineIndex.offset(forLine: first)
        let end = last < lineCount
            ? lineIndex.offset(forLine: last + 1)
            : (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: start, length: max(0, end - start)))
    }

    /// The 1-based lines the text view's selection touches; nil when empty.
    /// A selection that ends exactly at a line start does not include that line.
    func selectedLineRange(in textView: NSTextView) -> ClosedRange<Int>? {
        let range = textView.selectedRange()
        guard range.length > 0 else { return nil }
        let first = lineIndex.lineNumber(containingUTF16Offset: range.location)
        let endOffset = range.location + range.length
        var last = lineIndex.lineNumber(containingUTF16Offset: endOffset)
        if last > first, lineIndex.offset(forLine: last) == endOffset {
            last -= 1
        }
        return first...max(first, last)
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView = clientView as? NSTextView else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let line = lineNumber(atGutterPoint: point) else { return }
        let anchor: Int
        if event.modifierFlags.contains(.shift), let existing = selectedLineRange(in: textView) {
            // Shift extends from the far end of what is selected.
            anchor = line >= existing.upperBound ? existing.lowerBound : existing.upperBound
        } else {
            anchor = line
        }
        selectionAnchorLine = anchor
        selectLines(from: anchor, to: line, in: textView)
        window?.makeFirstResponder(textView)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = selectionAnchorLine,
              let textView = clientView as? NSTextView else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let line = lineNumber(atGutterPoint: point) else { return }
        selectLines(from: anchor, to: line, in: textView)
        textView.autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        selectionAnchorLine = nil
    }

    /// The numbers select lines, so the pointer is an arrow over them, not
    /// the text view's I-beam.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    // MARK: - Prompt button

    private func makePromptButton() -> NSButton {
        let label = String(localized: "filePreview.addToPrompt", defaultValue: "Add to prompt")
        // Same look as the diff viewer's gutter button: a small accent tile
        // with a white speech bubble.
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: Self.promptButtonSize, height: Self.promptButtonSize))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = Self.speechBubbleImage()
        button.imageScaling = .scaleNone
        button.wantsLayer = true
        button.layer?.cornerRadius = 4
        button.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = #selector(insertPromptReferenceForSelection(_:))
        button.isHidden = true
        addSubview(button)
        return button
    }

    /// The diff viewer's bubble, drawn here at 11pt in white: a rounded
    /// body with a tail at the bottom left. A system symbol this small
    /// loses its shape.
    private static func speechBubbleImage() -> NSImage {
        let size = NSSize(width: 11, height: 11)
        let image = NSImage(size: size, flipped: false) { _ in
            let path = NSBezierPath()
            // Body, as the diff viewer's SVG path, scaled from 24 to 11.
            let s: CGFloat = 11 / 24
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: x * s, y: (24 - y) * s)
            }
            path.move(to: point(4, 2))
            path.line(to: point(20, 2))
            path.curve(to: point(22, 4), controlPoint1: point(21.1, 2), controlPoint2: point(22, 2.9))
            path.line(to: point(22, 16))
            path.curve(to: point(20, 18), controlPoint1: point(22, 17.1), controlPoint2: point(21.1, 18))
            path.line(to: point(12, 18))
            path.line(to: point(8, 22))
            path.line(to: point(8, 18))
            path.line(to: point(4, 18))
            path.curve(to: point(2, 16), controlPoint1: point(2.9, 18), controlPoint2: point(2, 17.1))
            path.line(to: point(2, 4))
            path.curve(to: point(4, 2), controlPoint1: point(2, 2.9), controlPoint2: point(2.9, 2))
            path.close()
            NSColor.white.setFill()
            path.fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc private func insertPromptReferenceForSelection(_ sender: Any?) {
        guard let textView = clientView as? NSTextView,
              let lines = selectedLineRange(in: textView) else { return }
        onInsertPromptReference?(lines.lowerBound, lines.upperBound)
    }

    /// Whether the prompt button is showing on a selection.
    var isPromptButtonVisible: Bool {
        !promptButton.isHidden
    }

    /// Moves the prompt button onto the selection's last line, or hides it
    /// when nothing is selected or no prompt takes references.
    func updatePromptButton() {
        guard onInsertPromptReference != nil,
              let textView = clientView as? NSTextView,
              let lines = selectedLineRange(in: textView),
              let y = rulerY(forLine: lines.upperBound) else {
            promptButton.isHidden = true
            return
        }
        promptButton.frame = NSRect(
            x: max(0, ruleThickness - Self.promptButtonColumnWidth + 2),
            y: y,
            width: Self.promptButtonSize,
            height: Self.promptButtonSize
        )
        promptButton.isHidden = false
    }

    /// Presses the prompt button; for tests.
    func performPromptButtonClick() {
        guard isPromptButtonVisible else { return }
        insertPromptReferenceForSelection(promptButton)
    }

    private func rulerY(forLine line: Int) -> CGFloat? {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager else { return nil }
        let offset = lineIndex.offset(forLine: line)
        let rect: NSRect
        if offset < (textView.string as NSString).length {
            // The used rect leaves out the ghost gap above the line, so the
            // button sits on the line itself, not on the deleted lines.
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: offset)
            rect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        } else {
            rect = layoutManager.extraLineFragmentRect
            guard rect.height > 0 else { return nil }
        }
        let top = convert(NSPoint(x: 0, y: rect.minY + textView.textContainerOrigin.y), from: textView).y
        return top + max(0, (rect.height - Self.promptButtonSize) / 2)
    }
}
