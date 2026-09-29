import Foundation

/// Resolves "Go to Line" input against a buffer: `line` or `line:column`,
/// 1-based, clamped to the text. Line geometry comes from
/// `FilePreviewTextEditing.lineBounds(at:)`, walked from the top and stopped
/// at the requested line or the end of the buffer, whichever comes first.
struct FilePreviewLineLocator {
    struct Target: Equatable {
        let line: Int
        let column: Int?
    }

    private let editing: FilePreviewTextEditing

    init(text: String) {
        editing = FilePreviewTextEditing(text: text, indentation: Self.unusedIndentation())
    }

    /// Only line geometry is read here; no command that needs indentation
    /// runs on the locator's `editing`, so its lazy provider never fires.
    private static func unusedIndentation() -> FilePreviewIndentation {
        preconditionFailure("the line locator never reads indentation")
    }

    /// Parses `"12"`, `"12:5"`, or `"12,5"` (surrounding whitespace and a
    /// leading `:` before the line are ignored). Returns `nil` for anything
    /// that is not a positive line number.
    static func parse(_ input: String) -> Target? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "," })
        guard let first = parts.first, let line = Int(first.trimmingCharacters(in: .whitespaces)), line >= 1 else {
            return nil
        }
        guard parts.count == 2 else { return Target(line: line, column: nil) }
        let columnText = parts[1].trimmingCharacters(in: .whitespaces)
        if columnText.isEmpty { return Target(line: line, column: nil) }
        guard let column = Int(columnText), column >= 1 else { return nil }
        return Target(line: line, column: column)
    }

    /// Number of lines; an empty buffer has one, and a trailing terminator
    /// starts an empty last line.
    var lineCount: Int {
        walk(toLine: .max).number
    }

    /// The 1-based line containing `location`.
    func lineNumber(at location: Int) -> Int {
        let target = max(0, min(location, editing.text.length))
        var number = 1
        var line = editing.lineBounds(at: 0)
        while line.end <= target, Self.hasTerminator(line) {
            line = editing.lineBounds(at: line.end)
            number += 1
        }
        return number
    }

    /// The selection for `line` (clamped to `1...lineCount`): the whole line
    /// without its terminator, or a caret at `column` (clamped to the line's
    /// content plus one) when a column is given.
    func range(line: Int, column: Int?) -> NSRange {
        let bounds = walk(toLine: max(1, line)).line
        guard let column else {
            return NSRange(location: bounds.start, length: bounds.contentsEnd - bounds.start)
        }
        let offset = max(0, min(column - 1, bounds.contentsEnd - bounds.start))
        return NSRange(location: bounds.start + offset, length: 0)
    }

    /// Walks from the first line to `target` (1-based) or the last line.
    private func walk(toLine target: Int) -> (number: Int, line: FilePreviewTextEditing.LineBounds) {
        var number = 1
        var line = editing.lineBounds(at: 0)
        while number < target, Self.hasTerminator(line) {
            line = editing.lineBounds(at: line.end)
            number += 1
        }
        return (number, line)
    }

    /// A line with a terminator is followed by another line, possibly empty.
    private static func hasTerminator(_ line: FilePreviewTextEditing.LineBounds) -> Bool {
        line.end > line.contentsEnd
    }
}
