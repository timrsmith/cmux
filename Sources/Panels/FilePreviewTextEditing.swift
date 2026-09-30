import Foundation

/// One replacement inside the editor's text, in UTF-16 offsets of the text
/// the edit was computed against.
struct FilePreviewTextEdit: Equatable {
    let range: NSRange
    let replacement: String
}

/// The non-overlapping edits a command produces plus the selection to apply
/// once they are in place (post-edit coordinates).
struct FilePreviewTextEditResult: Equatable {
    let edits: [FilePreviewTextEdit]
    let selection: NSRange
}

/// Pure line-editing commands over `(text, selection)`.
///
/// Every command returns the replacement edits and the new selection instead
/// of touching a view, so the text view can route them through
/// `shouldChangeText(inRanges:replacementStrings:)` for undo and the tests can
/// check them without a window. Offsets are UTF-16 (`NSRange`).
struct FilePreviewTextEditing {
    let text: NSString
    private let indentationProvider: () -> FilePreviewIndentation

    /// `indentation` is evaluated on first use, so the whole-line commands
    /// (comment, move, duplicate, delete) never pay for detection; the text
    /// view keeps the detected value cached per buffer revision.
    init(text: String, indentation: @autoclosure @escaping () -> FilePreviewIndentation) {
        self.text = text as NSString
        indentationProvider = indentation
    }

    /// The file's indentation unit, read only by Return, Tab, and Shift-Tab.
    var indentation: FilePreviewIndentation { indentationProvider() }

    // MARK: Return, Tab, Shift-Tab

    /// Return: a newline plus the current line's leading whitespace, one level
    /// deeper when the text before the caret ends in `{`, `(`, `[`, or `:`.
    func newlineInsertion(at selection: NSRange) -> FilePreviewTextEditResult {
        let selection = clamped(selection)
        let line = lineBounds(at: selection.location)
        var indentEnd = line.start
        let leadingLimit = min(line.contentsEnd, selection.location)
        while indentEnd < leadingLimit, Self.isIndentCharacter(text.character(at: indentEnd)) {
            indentEnd += 1
        }
        var indent = text.substring(with: NSRange(location: line.start, length: indentEnd - line.start))
        var probe = selection.location - 1
        while probe >= line.start, Self.isIndentCharacter(text.character(at: probe)) {
            probe -= 1
        }
        if probe >= line.start, Self.opensIndentedBlock(text.character(at: probe)) {
            indent += indentation.unit
        }
        let replacement = lineTerminator + indent
        return FilePreviewTextEditResult(
            edits: [FilePreviewTextEdit(range: selection, replacement: replacement)],
            selection: NSRange(location: selection.location + (replacement as NSString).length, length: 0)
        )
    }

    /// Tab: indents every selected line when the selection spans a line
    /// break; otherwise inserts one indentation unit (spaces pad to the next
    /// tab stop) in place of the selection.
    func tabInsertion(at selection: NSRange) -> FilePreviewTextEditResult {
        let selection = clamped(selection)
        if selection.length > 0, lines(in: lineBlockRange(for: selection)).count > 1 {
            return indentLines(in: selection)
        }
        let indentation = self.indentation
        let replacement: String
        if indentation.usesTabs {
            replacement = "\t"
        } else {
            let column = selection.location - lineBounds(at: selection.location).start
            replacement = String(repeating: " ", count: indentation.width - (column % indentation.width))
        }
        return FilePreviewTextEditResult(
            edits: [FilePreviewTextEdit(range: selection, replacement: replacement)],
            selection: NSRange(location: selection.location + (replacement as NSString).length, length: 0)
        )
    }

    /// Inserts one indentation unit at the start of every non-blank selected line.
    func indentLines(in selection: NSRange) -> FilePreviewTextEditResult {
        let selection = clamped(selection)
        let unit = indentation.unit
        var edits: [FilePreviewTextEdit] = []
        for line in lines(in: lineBlockRange(for: selection)) where line.contentsEnd > line.start {
            edits.append(FilePreviewTextEdit(range: NSRange(location: line.start, length: 0), replacement: unit))
        }
        return FilePreviewTextEditResult(edits: edits, selection: adjustedSelection(selection, for: edits))
    }

    /// Removes one indentation unit (a tab, or up to `width` spaces) from the
    /// start of every selected line that has one.
    func outdentLines(in selection: NSRange) -> FilePreviewTextEditResult {
        let selection = clamped(selection)
        let unitWidth = indentation.width
        var edits: [FilePreviewTextEdit] = []
        for line in lines(in: lineBlockRange(for: selection)) {
            let removed = leadingIndentUnitLength(in: line, unitWidth: unitWidth)
            if removed > 0 {
                edits.append(FilePreviewTextEdit(range: NSRange(location: line.start, length: removed), replacement: ""))
            }
        }
        return FilePreviewTextEditResult(edits: edits, selection: adjustedSelection(selection, for: edits))
    }

    // MARK: Line comments

    /// Comments every selected line with `token` at the block's shallowest
    /// indentation, or uncomments them when every non-blank line already
    /// starts with `token`. Blank lines are skipped unless the whole
    /// selection is blank. Returns `nil` where there is no line: an empty
    /// document, or the empty position after a trailing line break.
    func toggleLineComment(in selection: NSRange, token: String) -> FilePreviewTextEditResult? {
        let selection = clamped(selection)
        let block = lineBlockRange(for: selection)
        guard block.length > 0 else { return nil }
        let tokenLength = (token as NSString).length
        let nonBlankLines = lines(in: block).filter { firstNonIndentIndex(in: $0) < $0.contentsEnd }
        var edits: [FilePreviewTextEdit] = []
        guard !nonBlankLines.isEmpty else {
            edits.append(FilePreviewTextEdit(range: NSRange(location: block.location, length: 0), replacement: token + " "))
            return FilePreviewTextEditResult(edits: edits, selection: adjustedSelection(selection, for: edits))
        }
        let allCommented = nonBlankLines.allSatisfy { line in
            let contentStart = firstNonIndentIndex(in: line)
            return contentStart + tokenLength <= line.contentsEnd
                && text.substring(with: NSRange(location: contentStart, length: tokenLength)) == token
        }
        if allCommented {
            for line in nonBlankLines {
                let contentStart = firstNonIndentIndex(in: line)
                var length = tokenLength
                if contentStart + length < line.contentsEnd, text.character(at: contentStart + length) == 0x20 {
                    length += 1
                }
                edits.append(FilePreviewTextEdit(range: NSRange(location: contentStart, length: length), replacement: ""))
            }
        } else {
            let minimumIndent = nonBlankLines.map { firstNonIndentIndex(in: $0) - $0.start }.min() ?? 0
            for line in nonBlankLines {
                edits.append(FilePreviewTextEdit(
                    range: NSRange(location: line.start + minimumIndent, length: 0),
                    replacement: token + " "
                ))
            }
        }
        return FilePreviewTextEditResult(edits: edits, selection: adjustedSelection(selection, for: edits))
    }

    // MARK: Whole-line commands

    /// Swaps the selected lines with the line above (`up`) or below. Returns
    /// `nil` at the first or last line.
    ///
    /// When the last line of the file takes part it has no terminator, so
    /// the break that separated the two lines moves with them: the file keeps
    /// exactly the terminators it had (`"\r\n"` stays `"\r\n"`).
    func moveLines(in selection: NSRange, up: Bool) -> FilePreviewTextEditResult? {
        let selection = clamped(selection)
        let block = lineBlockRange(for: selection)
        let blockText = text.substring(with: block)
        let blockHasNewline = endsWithLineBreak(block)
        if up {
            guard block.location > 0 else { return nil }
            let previous = lineBounds(at: block.location - 1)
            let replacement: String
            if blockHasNewline {
                replacement = blockText + substring(from: previous.start, to: previous.end)
            } else {
                replacement = blockText
                    + substring(from: previous.contentsEnd, to: previous.end)
                    + substring(from: previous.start, to: previous.contentsEnd)
            }
            let edit = FilePreviewTextEdit(
                range: NSRange(location: previous.start, length: NSMaxRange(block) - previous.start),
                replacement: replacement
            )
            return FilePreviewTextEditResult(
                edits: [edit],
                selection: NSRange(location: selection.location - (previous.end - previous.start), length: selection.length)
            )
        }
        guard NSMaxRange(block) < text.length, blockHasNewline else { return nil }
        let next = lineBounds(at: NSMaxRange(block))
        let nextText = substring(from: next.start, to: next.end)
        let replacement: String
        // How far the block moves: past the next line, plus the separator
        // that now precedes it when the next line had none of its own.
        let shift: Int
        if next.end > next.contentsEnd {
            replacement = nextText + blockText
            shift = next.end - next.start
        } else {
            let lastLine = lineBounds(at: NSMaxRange(block) - 1)
            let separator = substring(from: lastLine.contentsEnd, to: lastLine.end)
            replacement = nextText + separator + substring(from: block.location, to: lastLine.contentsEnd)
            shift = next.end - next.start + (separator as NSString).length
        }
        let edit = FilePreviewTextEdit(
            range: NSRange(location: block.location, length: next.end - block.location),
            replacement: replacement
        )
        return FilePreviewTextEditResult(
            edits: [edit],
            selection: NSRange(location: selection.location + shift, length: selection.length)
        )
    }

    /// Inserts a copy of the selected lines below them and moves the
    /// selection onto the copy. Returns `nil` where there is no line to copy
    /// (an empty document, or the empty position after a trailing line break).
    func duplicateLines(in selection: NSRange) -> FilePreviewTextEditResult? {
        let selection = clamped(selection)
        let block = lineBlockRange(for: selection)
        guard block.length > 0 else { return nil }
        let blockText = text.substring(with: block)
        let replacement = endsWithLineBreak(block) ? blockText : lineTerminator + blockText
        let edit = FilePreviewTextEdit(range: NSRange(location: NSMaxRange(block), length: 0), replacement: replacement)
        return FilePreviewTextEditResult(
            edits: [edit],
            selection: NSRange(location: selection.location + (replacement as NSString).length, length: selection.length)
        )
    }

    /// Removes the selected lines, keeping the caret's column on the line
    /// that takes their place. On the last line, which has no terminator of
    /// its own, the whole terminator before it goes (both characters of a
    /// `"\r\n"`); on the empty position after a trailing line break that is
    /// the trailing break itself. Returns `nil` for an empty document.
    func deleteLines(in selection: NSRange) -> FilePreviewTextEditResult? {
        let selection = clamped(selection)
        let block = lineBlockRange(for: selection)
        guard block.length > 0 || block.location > 0 else { return nil }
        let column = selection.location - lineBounds(at: selection.location).start
        let removed: NSRange
        let caret: Int
        if endsWithLineBreak(block) {
            removed = block
            let following = lineBounds(at: NSMaxRange(block))
            caret = block.location + min(column, following.contentsEnd - following.start)
        } else if block.location > 0 {
            let previous = lineBounds(at: block.location - 1)
            removed = NSRange(location: previous.contentsEnd, length: NSMaxRange(block) - previous.contentsEnd)
            caret = previous.start + min(column, previous.contentsEnd - previous.start)
        } else {
            removed = block
            caret = 0
        }
        return FilePreviewTextEditResult(
            edits: [FilePreviewTextEdit(range: removed, replacement: "")],
            selection: NSRange(location: caret, length: 0)
        )
    }

    // MARK: Line terminator

    /// The line break a command inserts (Return, Duplicate Line on the last
    /// line): `"\r\n"` when the first line break in the document is one,
    /// otherwise `"\n"`. A mixed file follows its first line. Read once per
    /// command, only by the commands that insert a break.
    var lineTerminator: String {
        let newline = text.range(of: "\n")
        guard newline.location != NSNotFound else { return "\n" }
        if newline.location > 0, text.character(at: newline.location - 1) == 0x0D {
            return "\r\n"
        }
        return "\n"
    }

    private func substring(from start: Int, to end: Int) -> String {
        text.substring(with: NSRange(location: start, length: end - start))
    }

    // MARK: Line geometry

    struct LineBounds: Equatable {
        let start: Int
        let end: Int
        let contentsEnd: Int
    }

    /// Range of every line the selection touches, through the last line's
    /// terminator when it has one. A selection that ends exactly at a line
    /// start does not include that line.
    func lineBlockRange(for selection: NSRange) -> NSRange {
        let selection = clamped(selection)
        let start = lineBounds(at: selection.location).start
        var endLocation = NSMaxRange(selection)
        if selection.length > 0, endLocation > selection.location, isLineStart(endLocation) {
            endLocation -= 1
        }
        let last = lineBounds(at: endLocation)
        return NSRange(location: start, length: last.end - start)
    }

    func lineBounds(at location: Int) -> LineBounds {
        var start = 0
        var end = 0
        var contentsEnd = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: min(location, text.length), length: 0))
        return LineBounds(start: start, end: end, contentsEnd: contentsEnd)
    }

    func lines(in block: NSRange) -> [LineBounds] {
        var result: [LineBounds] = []
        var location = block.location
        let limit = NSMaxRange(block)
        repeat {
            let line = lineBounds(at: location)
            result.append(line)
            guard line.end > location else { break }
            location = line.end
        } while location < limit
        return result
    }

    private func isLineStart(_ location: Int) -> Bool {
        guard location > 0, location <= text.length else { return location == 0 }
        return Self.isLineBreak(text.character(at: location - 1))
    }

    private func endsWithLineBreak(_ range: NSRange) -> Bool {
        range.length > 0 && Self.isLineBreak(text.character(at: NSMaxRange(range) - 1))
    }

    private func firstNonIndentIndex(in line: LineBounds) -> Int {
        var index = line.start
        while index < line.contentsEnd, Self.isIndentCharacter(text.character(at: index)) {
            index += 1
        }
        return index
    }

    private func leadingIndentUnitLength(in line: LineBounds, unitWidth: Int) -> Int {
        guard line.contentsEnd > line.start else { return 0 }
        if text.character(at: line.start) == 0x09 { return 1 }
        var count = 0
        while count < unitWidth, line.start + count < line.contentsEnd,
              text.character(at: line.start + count) == 0x20 {
            count += 1
        }
        return count
    }

    private func clamped(_ range: NSRange) -> NSRange {
        let location = max(0, min(range.location, text.length))
        let length = max(0, min(range.length, text.length - location))
        return NSRange(location: location, length: length)
    }

    /// Projects `selection` through `edits` (original coordinates): an
    /// insertion at the selection start stays selected, a removal that
    /// straddles an endpoint clamps it to the removal's start.
    private func adjustedSelection(_ selection: NSRange, for edits: [FilePreviewTextEdit]) -> NSRange {
        let start = selection.location
        let end = NSMaxRange(selection)
        var newStart = start
        var newEnd = end
        for edit in edits {
            let inserted = (edit.replacement as NSString).length
            let removedEnd = NSMaxRange(edit.range)
            if edit.range.length == 0 {
                if edit.range.location < start || (edit.range.location == start && selection.length == 0) { newStart += inserted }
                if edit.range.location < end || (edit.range.location == end && selection.length == 0) { newEnd += inserted }
            } else {
                if removedEnd <= start {
                    newStart -= edit.range.length
                } else if edit.range.location < start {
                    newStart -= start - edit.range.location
                }
                if removedEnd <= end {
                    newEnd -= edit.range.length
                } else if edit.range.location < end {
                    newEnd -= end - edit.range.location
                }
                newStart += edit.range.location < start ? inserted : 0
                newEnd += edit.range.location < end ? inserted : 0
            }
        }
        return NSRange(location: max(0, newStart), length: max(0, newEnd - newStart))
    }

    static func isIndentCharacter(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
    }

    static func isLineBreak(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x0D || character == 0x85 || character == 0x2028 || character == 0x2029
    }

    private static func opensIndentedBlock(_ character: unichar) -> Bool {
        character == 0x7B || character == 0x28 || character == 0x5B || character == 0x3A
    }
}
