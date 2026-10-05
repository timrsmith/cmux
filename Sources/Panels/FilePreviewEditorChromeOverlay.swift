import AppKit
import CmuxFoundation

/// Draws current-line highlight and indent guides over a TextKit 1 text view.
///
/// Hits are ignored so clicks reach the text view. The overlay is a subview of
/// the text view so it scrolls with the document.
final class FilePreviewEditorChromeOverlay: NSView {
    weak var textView: NSTextView?
    var showsCurrentLine = true
    var showsIndentGuides = true
    var tabWidth = 4
    var currentLineColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.12)
    var indentGuideColor = NSColor.separatorColor.withAlphaComponent(0.55)
    /// UTF-16 ranges of the lines that differ from git's index, tinted like
    /// the diff viewer's added lines. The gutter keeps them current.
    var changedLineRanges: [NSRange] = [] {
        didSet { if changedLineRanges != oldValue { needsDisplay = true } }
    }
    /// Lines deleted from git's index, shown read-only in a gap above the
    /// line they used to precede, or below the last line for an offset at
    /// the end of the text. The gap is paragraph spacing on that line, so
    /// the document, its numbering and its undo stack never contain them.
    struct DeletedLineBlock: Equatable {
        /// UTF-16 start of the line the deleted lines sat before.
        let offset: Int
        /// The first deleted line's number in the base, for the gutter.
        let baseStart: Int
        let lines: [String]
    }
    var deletedLineBlocks: [DeletedLineBlock] = [] {
        didSet {
            guard deletedLineBlocks != oldValue else { return }
            applyGhostGapSpacing()
            needsDisplay = true
        }
    }
    var changedLineColor = NSColor.systemGreen.withAlphaComponent(0.14)
    var deletedLineColor = NSColor.systemRed.withAlphaComponent(0.14)
    /// Paragraphs carrying ghost-gap spacing, cleared before the next apply.
    private var ghostParagraphRanges: [NSRange] = []

    deinit {}

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        drawChangeHighlights(in: dirtyRect, textView: textView, layoutManager: layoutManager)
        if showsCurrentLine {
            drawCurrentLine(in: textView, layoutManager: layoutManager)
        }
        if showsIndentGuides {
            drawIndentGuides(
                in: dirtyRect,
                textView: textView,
                layoutManager: layoutManager,
                textContainer: textContainer
            )
        }
    }

    static func installed(in textView: NSTextView) -> FilePreviewEditorChromeOverlay? {
        textView.subviews.compactMap { $0 as? FilePreviewEditorChromeOverlay }.first
    }

    func syncFrame(to textView: NSTextView) {
        let next = textView.bounds
        if frame != next {
            frame = next
        }
        needsDisplay = true
    }

    private func drawCurrentLine(
        in textView: NSTextView,
        layoutManager: NSLayoutManager
    ) {
        let selected = textView.selectedRange()
        guard selected.length == 0 else { return }
        let stringLength = (textView.string as NSString).length
        let location = min(max(selected.location, 0), stringLength)
        let glyphCount = layoutManager.numberOfGlyphs
        let origin = textView.textContainerOrigin
        let fallbackHeight = max(textView.font?.boundingRectForFont.height ?? 16, 1)
        let nsString = textView.string as NSString

        // TextKit represents an empty buffer and the line after a terminal
        // newline with `extraLineFragmentRect`, not a glyph. Prefer that
        // explicit rect so wrapped lines use their real visual position.
        let isExtraLine = stringLength == 0
            || (location == stringLength && Self.endsWithLineBreak(nsString))
        if isExtraLine {
            let extra = layoutManager.extraLineFragmentRect
            if Self.isUsableLineRect(extra) {
                fillCurrentLineBand(
                    atY: extra.minY + origin.y,
                    height: max(extra.height, fallbackHeight),
                    in: textView
                )
            } else if stringLength == 0 {
                // A freshly created TextKit stack may not have populated the
                // extra-line rect yet, but the empty editor still has a valid
                // first line at the text-container origin.
                fillCurrentLineBand(atY: origin.y, height: fallbackHeight, in: textView)
            } else if glyphCount > 0 {
                // If the extra-line metadata has not been populated yet, use
                // the last realized fragment. Do not force layout from draw:
                // a long non-contiguous line could otherwise block the main
                // actor while the overlay is painting.
                var lastRange = NSRange()
                let lastFragment = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphCount - 1,
                    effectiveRange: &lastRange,
                    withoutAdditionalLayout: true
                )
                if Self.isUsableLineRect(lastFragment) {
                    fillCurrentLineBand(
                        atY: lastFragment.maxY + origin.y,
                        height: max(lastFragment.height, fallbackHeight),
                        in: textView
                    )
                }
            }
            return
        }

        // At EOF in a non-empty, non-newline-terminated buffer, use the final
        // real character. Never pass the insertion-point glyph index.
        guard glyphCount > 0 else { return }
        let characterIndex = min(location, stringLength - 1)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
        guard glyphIndex >= 0, glyphIndex < glyphCount else { return }
        var lineRange = NSRange()
        // The used rect excludes paragraph spacing, so the band stays off a
        // ghost gap above the line.
        let fragment = layoutManager.lineFragmentUsedRect(
            forGlyphAt: glyphIndex,
            effectiveRange: &lineRange,
            withoutAdditionalLayout: true
        )
        // `allowsNonContiguousLayout` can leave a caret's fragment unrealized.
        // Never force a potentially huge synchronous layout from draw; the
        // next TextKit invalidation will repaint after that fragment is ready.
        guard Self.isUsableLineRect(fragment) else { return }
        let y = fragment.minY + origin.y
        fillCurrentLineBand(
            atY: y,
            height: max(fragment.height, fallbackHeight),
            in: textView
        )
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

    /// Tints the changed lines, fragment by fragment, and paints the deleted
    /// lines into their gaps, without forcing layout: a fragment TextKit has
    /// not laid out yet paints once it is. The used rect excludes paragraph
    /// spacing, so a changed line's tint never covers the gap above it.
    private func drawChangeHighlights(
        in dirtyRect: NSRect,
        textView: NSTextView,
        layoutManager: NSLayoutManager
    ) {
        guard !changedLineRanges.isEmpty || !deletedLineBlocks.isEmpty else { return }
        let origin = textView.textContainerOrigin
        let stringLength = (textView.string as NSString).length
        let glyphCount = layoutManager.numberOfGlyphs
        let width = max(bounds.width, textView.bounds.width)

        changedLineColor.setFill()
        for range in changedLineRanges where range.length > 0 && range.location < stringLength {
            var glyphIndex = layoutManager.glyphIndexForCharacter(at: range.location)
            let endGlyph = layoutManager.glyphIndexForCharacter(at: min(NSMaxRange(range), stringLength))
            while glyphIndex < min(endGlyph, glyphCount) {
                var fragmentRange = NSRange()
                let used = layoutManager.lineFragmentUsedRect(
                    forGlyphAt: glyphIndex,
                    effectiveRange: &fragmentRange,
                    withoutAdditionalLayout: true
                )
                guard Self.isUsableLineRect(used), fragmentRange.length > 0 else { break }
                let band = NSRect(x: 0, y: used.minY + origin.y, width: width, height: used.height)
                if band.intersects(dirtyRect) {
                    band.fill()
                }
                glyphIndex = NSMaxRange(fragmentRange)
            }
        }

        for block in deletedLineBlocks {
            guard let gap = ghostGapRect(for: block, textView: textView, layoutManager: layoutManager),
                  gap.intersects(dirtyRect) else { continue }
            deletedLineColor.setFill()
            NSRect(x: 0, y: gap.minY, width: width, height: gap.height).fill()
            drawGhostLines(block, in: gap, textView: textView, layoutManager: layoutManager)
        }
    }

    // MARK: - Ghost gaps

    /// Reserves each block's gap as paragraph spacing before the line it
    /// precedes, or after the last paragraph for a block at the end of the
    /// text. Direct storage attribute writes: no undo entry, no text change.
    /// Called again after any sweep that rewrites paragraph styles.
    func applyGhostGapSpacing() {
        guard let textView, let storage = textView.textStorage else { return }
        let nsString = storage.string as NSString
        let length = nsString.length
        storage.beginEditing()
        for range in ghostParagraphRanges where range.length > 0 && NSMaxRange(range) <= length {
            setGhostSpacing(before: 0, after: 0, in: range, storage: storage, textView: textView)
        }
        ghostParagraphRanges = []
        for block in deletedLineBlocks {
            let height = ghostGapHeight(for: block, textView: textView)
            guard height > 0 else { continue }
            if block.offset < length {
                let paragraph = nsString.paragraphRange(for: NSRange(location: block.offset, length: 0))
                guard paragraph.length > 0 else { continue }
                setGhostSpacing(before: height, after: nil, in: paragraph, storage: storage, textView: textView)
                ghostParagraphRanges.append(paragraph)
            } else if length > 0 {
                let paragraph = nsString.paragraphRange(for: NSRange(location: length - 1, length: 0))
                setGhostSpacing(before: nil, after: height, in: paragraph, storage: storage, textView: textView)
                ghostParagraphRanges.append(paragraph)
            }
        }
        storage.endEditing()
        needsDisplay = true
    }

    private func setGhostSpacing(
        before: CGFloat?,
        after: CGFloat?,
        in range: NSRange,
        storage: NSTextStorage,
        textView: NSTextView
    ) {
        let existing = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            ?? textView.defaultParagraphStyle
            ?? NSParagraphStyle.default
        let style = NSMutableParagraphStyle()
        style.setParagraphStyle(existing)
        if let before { style.paragraphSpacingBefore = before }
        if let after { style.paragraphSpacing = after }
        storage.addAttribute(.paragraphStyle, value: style, range: range)
    }

    /// The height each deleted line takes in its gap: one row, or its wrapped
    /// height when the editor wraps. The gutter numbers the rows from these.
    func ghostRowHeights(for block: DeletedLineBlock) -> [CGFloat] {
        guard let textView, let layoutManager = textView.layoutManager else { return [] }
        let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let rowHeight = layoutManager.defaultLineHeight(for: font)
        guard let wrapWidth = ghostWrapWidth(in: textView) else {
            return Array(repeating: rowHeight, count: block.lines.count)
        }
        return block.lines.map { line in
            let measured = NSAttributedString(string: line.isEmpty ? " " : line, attributes: [.font: font])
                .boundingRect(with: NSSize(width: wrapWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
            return max(rowHeight, ceil(measured.height / rowHeight) * rowHeight)
        }
    }

    private func ghostGapHeight(for block: DeletedLineBlock, textView: NSTextView) -> CGFloat {
        ghostRowHeights(for: block).reduce(0, +)
    }

    /// The width ghost lines wrap at; nil when the editor does not wrap.
    private func ghostWrapWidth(in textView: NSTextView) -> CGFloat? {
        guard let container = textView.textContainer, container.widthTracksTextView else { return nil }
        let width = container.size.width - 2 * container.lineFragmentPadding
        return width.isFinite && width > 0 ? width : nil
    }

    /// The gap a block occupies, in the overlay's coordinates: the spacing
    /// above its line's first fragment, or below the last fragment.
    private func ghostGapRect(
        for block: DeletedLineBlock,
        textView: NSTextView,
        layoutManager: NSLayoutManager
    ) -> NSRect? {
        let origin = textView.textContainerOrigin
        let stringLength = (textView.string as NSString).length
        let glyphCount = layoutManager.numberOfGlyphs
        guard glyphCount > 0 else { return nil }
        if block.offset < stringLength {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: block.offset)
            guard glyphIndex < glyphCount else { return nil }
            let rect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil, withoutAdditionalLayout: true)
            let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil, withoutAdditionalLayout: true)
            guard Self.isUsableLineRect(rect), Self.isUsableLineRect(used), used.minY > rect.minY else { return nil }
            return NSRect(x: 0, y: rect.minY + origin.y, width: bounds.width, height: used.minY - rect.minY)
        }
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyphCount - 1, effectiveRange: nil, withoutAdditionalLayout: true)
        let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphCount - 1, effectiveRange: nil, withoutAdditionalLayout: true)
        guard Self.isUsableLineRect(rect), Self.isUsableLineRect(used), rect.maxY > used.maxY else { return nil }
        return NSRect(x: 0, y: used.maxY + origin.y, width: bounds.width, height: rect.maxY - used.maxY)
    }

    private func drawGhostLines(
        _ block: DeletedLineBlock,
        in gap: NSRect,
        textView: NSTextView,
        layoutManager: NSLayoutManager
    ) {
        let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let color = (textView.textColor ?? .textColor).withAlphaComponent(0.75)
        let x = textView.textContainerOrigin.x + (textView.textContainer?.lineFragmentPadding ?? 0)
        let width = ghostWrapWidth(in: textView) ?? CGFloat.greatestFiniteMagnitude
        var y = gap.minY
        for (line, height) in zip(block.lines, ghostRowHeights(for: block)) {
            let text = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: color])
            text.draw(with: NSRect(x: x, y: y, width: width, height: height), options: [.usesLineFragmentOrigin])
            y += height
        }
    }

    private func fillCurrentLineBand(atY y: CGFloat, height: CGFloat, in textView: NSTextView) {
        let band = NSRect(
            x: 0,
            y: y,
            width: max(bounds.width, textView.bounds.width),
            height: max(height, 1)
        )
        currentLineColor.setFill()
        band.fill()
    }

    private func drawIndentGuides(
        in dirtyRect: NSRect,
        textView: NSTextView,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) {
        let font = textView.font
            ?? GlobalFontMagnification.monospacedSystemFont(ofSize: 13, weight: .regular)
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        guard spaceWidth > 0.5 else { return }

        let origin = textView.textContainerOrigin
        let queryRect = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: queryRect, in: textContainer)
        let nsString = textView.string as NSString
        let columns = max(1, tabWidth)
        indentGuideColor.setStroke()

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            _, usedRect, _, fragmentGlyphRange, _ in
            let characterRange = layoutManager.characterRange(
                forGlyphRange: fragmentGlyphRange,
                actualGlyphRange: nil
            )
            guard characterRange.location == 0
                    || Self.isLineBreak(nsString.character(at: characterRange.location - 1)) else {
                return
            }
            let indentColumns = Self.leadingIndentColumns(
                in: nsString,
                lineStart: characterRange.location,
                tabWidth: columns
            )
            guard indentColumns >= columns else { return }
            var column = columns
            while column <= indentColumns {
                let guideX = origin.x + CGFloat(column) * spaceWidth
                let path = NSBezierPath()
                path.lineWidth = 1
                path.move(to: NSPoint(x: guideX + 0.5, y: usedRect.minY + origin.y))
                path.line(to: NSPoint(x: guideX + 0.5, y: usedRect.maxY + origin.y))
                path.stroke()
                column += columns
            }
        }
    }

    private static func isLineBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
    }

    static func leadingIndentColumns(
        in string: NSString,
        lineStart: Int,
        tabWidth: Int
    ) -> Int {
        var columns = 0
        var index = lineStart
        let length = string.length
        let tab = max(1, tabWidth)
        while index < length {
            let character = string.character(at: index)
            if character == 32 {
                columns += 1
            } else if character == 9 {
                columns = ((columns / tab) + 1) * tab
            } else {
                break
            }
            index += 1
        }
        return columns
    }
}
