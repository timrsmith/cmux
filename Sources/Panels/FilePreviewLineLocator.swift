import Foundation

/// Resolves "Go to Line" input against a buffer: `line` or `line:column`,
/// 1-based, clamped to the text.
struct FilePreviewLineLocator {
    struct Target: Equatable {
        let line: Int
        let column: Int?
    }

    let text: NSString

    init(text: String) {
        self.text = text as NSString
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

    /// Number of lines; an empty buffer has one.
    var lineCount: Int {
        var count = 1
        var location = 0
        while location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            guard line.length > 0 else { break }
            if NSMaxRange(line) < text.length || Self.endsWithLineBreak(text, line) {
                count += 1
            }
            location = NSMaxRange(line)
        }
        return count
    }

    /// The 1-based line containing `location`.
    func lineNumber(at location: Int) -> Int {
        let target = max(0, min(location, text.length))
        var number = 1
        var cursor = 0
        while cursor < target {
            let line = text.lineRange(for: NSRange(location: cursor, length: 0))
            guard line.length > 0, NSMaxRange(line) <= target, Self.endsWithLineBreak(text, line) else { break }
            number += 1
            cursor = NSMaxRange(line)
        }
        return number
    }

    /// The selection for `line` (clamped to `1...lineCount`): the whole line
    /// without its terminator, or a caret at `column` (clamped to the line's
    /// content plus one) when a column is given.
    func range(line: Int, column: Int?) -> NSRange {
        let targetLine = max(1, min(line, lineCount))
        var start = 0
        var number = 1
        while number < targetLine {
            let current = text.lineRange(for: NSRange(location: start, length: 0))
            guard current.length > 0 else { break }
            start = NSMaxRange(current)
            number += 1
        }
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
        guard let column else {
            return NSRange(location: lineStart, length: contentsEnd - lineStart)
        }
        let offset = max(0, min(column - 1, contentsEnd - lineStart))
        return NSRange(location: lineStart + offset, length: 0)
    }

    private static func endsWithLineBreak(_ text: NSString, _ range: NSRange) -> Bool {
        range.length > 0 && FilePreviewTextEditing.isLineBreak(text.character(at: NSMaxRange(range) - 1))
    }
}
