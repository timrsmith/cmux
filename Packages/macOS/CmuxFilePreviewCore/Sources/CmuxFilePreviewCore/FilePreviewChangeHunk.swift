import Foundation

/// One run of lines that differ between a base text (the file as git has it
/// in the index) and the text in the editor.
///
/// Line numbers are 1-based and follow ``FilePreviewLineIndex``: a trailing
/// newline opens a final empty line, so a file ending in `\n` has one more
/// line than it has newline-terminated lines. The base and current ranges
/// are empty for a pure insertion and a pure deletion respectively.
///
/// ```swift
/// let hunks = FilePreviewChangeHunks(base: "a\nb\n", current: "a\nB\nc\n")
/// hunks.hunks.first?.kind       // .modified (line 2)
/// hunks.hunks.last?.kind        // .added (line 3)
/// ```
public struct FilePreviewChangeHunk: Equatable, Sendable {
    /// How the editor shows the hunk in its gutter.
    public enum Kind: Equatable, Sendable {
        /// Lines present in the current text only.
        case added
        /// Lines present in the base only; they sat before ``currentStart``.
        case deleted
        /// Lines replaced: both ranges are non-empty.
        case modified
    }

    /// First base line of the hunk; the line the deleted lines sat at, or
    /// for a pure insertion the base line that follows the insertion point.
    public let baseStart: Int
    /// Base lines the hunk replaces; zero for a pure insertion.
    public let baseCount: Int
    /// First current line of the hunk; for a pure deletion, the current line
    /// the deleted lines used to precede.
    public let currentStart: Int
    /// Current lines the hunk covers; zero for a pure deletion.
    public let currentCount: Int
    /// The base lines, what a revert puts back.
    public let baseLines: [String]

    public init(baseStart: Int, baseCount: Int, currentStart: Int, currentCount: Int, baseLines: [String]) {
        self.baseStart = baseStart
        self.baseCount = baseCount
        self.currentStart = currentStart
        self.currentCount = currentCount
        self.baseLines = baseLines
    }

    public var kind: Kind {
        if baseCount == 0 { return .added }
        if currentCount == 0 { return .deleted }
        return .modified
    }

    /// The current line the gutter marks for this hunk; a deleted hunk marks
    /// the line it used to precede.
    public var markerLine: Int { currentStart }

    /// Whether a click on the marker of `line` in the current text belongs
    /// to this hunk. A deletion owns only the line it sits above.
    public func covers(currentLine line: Int) -> Bool {
        if currentCount == 0 { return line == currentStart }
        return line >= currentStart && line < currentStart + currentCount
    }
}
