public import Foundation

/// The hunks that turn a base text into the current text, computed from a
/// line-level diff, plus the edit that reverts one hunk in the current text.
///
/// Lines are split on `\n` only; a carriage return stays part of its line,
/// so the two texts are compared on equal terms whatever their endings.
public struct FilePreviewChangeHunks: Equatable, Sendable {
    public let hunks: [FilePreviewChangeHunk]

    /// Diffs `current` against `base` and groups the differing lines into
    /// hunks: adjacent removals and insertions become one modified hunk.
    public init(base: String, current: String) {
        let baseLines = Self.lines(of: base)
        let currentLines = Self.lines(of: current)
        let difference = currentLines.difference(from: baseLines)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var hunks: [FilePreviewChangeHunk] = []
        var baseIndex = 0
        var currentIndex = 0
        while baseIndex < baseLines.count || currentIndex < currentLines.count {
            let baseChanged = baseIndex < baseLines.count && removed.contains(baseIndex)
            let currentChanged = currentIndex < currentLines.count && inserted.contains(currentIndex)
            guard baseChanged || currentChanged else {
                baseIndex += 1
                currentIndex += 1
                continue
            }
            let baseStart = baseIndex
            let currentStart = currentIndex
            // A hunk runs until a line both texts share: removals and
            // insertions that touch belong together as one modification.
            while true {
                while baseIndex < baseLines.count, removed.contains(baseIndex) { baseIndex += 1 }
                while currentIndex < currentLines.count, inserted.contains(currentIndex) { currentIndex += 1 }
                let moreRemoved = baseIndex < baseLines.count && removed.contains(baseIndex)
                let moreInserted = currentIndex < currentLines.count && inserted.contains(currentIndex)
                if !moreRemoved && !moreInserted { break }
            }
            hunks.append(FilePreviewChangeHunk(
                baseStart: baseStart + 1,
                baseCount: baseIndex - baseStart,
                currentStart: currentStart + 1,
                currentCount: currentIndex - currentStart,
                baseLines: baseLines[baseStart..<baseIndex].map(String.init)
            ))
        }
        self.hunks = hunks
    }

    public init(hunks: [FilePreviewChangeHunk]) {
        self.hunks = hunks
    }

    public var isEmpty: Bool { hunks.isEmpty }

    /// The hunk whose marker a click on `line` of the current text hits.
    public func hunk(atCurrentLine line: Int) -> FilePreviewChangeHunk? {
        hunks.first { $0.covers(currentLine: line) }
    }

    /// The hunks whose current lines, or deletion point, fall inside
    /// `lines` (inclusive, 1-based), in document order.
    public func hunks(inCurrentLines lines: ClosedRange<Int>) -> [FilePreviewChangeHunk] {
        hunks.filter { hunk in
            let last = hunk.currentCount == 0 ? hunk.currentStart : hunk.currentStart + hunk.currentCount - 1
            return hunk.currentStart <= lines.upperBound && last >= lines.lowerBound
        }
    }

    /// The one text replacement that reverts `hunk` in `current`: the UTF-16
    /// range of the hunk's current lines (with their line breaks) and the
    /// base lines to put there. A deletion inserts at its line; a hunk at
    /// the very end of an unterminated file keeps the file unterminated.
    public static func revertEdit(
        for hunk: FilePreviewChangeHunk,
        in current: String
    ) -> (range: NSRange, replacement: String) {
        let index = FilePreviewLineIndex(string: current)
        let utf16Length = (current as NSString).length
        let lineCount = index.lineCount
        func lineStart(_ line: Int) -> Int {
            line <= lineCount ? index.offset(forLine: line) : utf16Length
        }
        var start = lineStart(hunk.currentStart)
        let endLine = hunk.currentStart + hunk.currentCount
        let end = lineStart(endLine)
        let joined = hunk.baseLines.joined(separator: "\n")
        let replacement: String
        if endLine <= lineCount {
            // Another line follows, so each replaced line owns its newline.
            replacement = hunk.baseLines.isEmpty ? "" : joined + "\n"
        } else if hunk.currentCount == 0 {
            // A deletion after the unterminated last line.
            replacement = hunk.baseLines.isEmpty ? "" : "\n" + joined
        } else {
            // The hunk ends the file without a newline: its lines own the
            // newline before them, and so does what replaces them.
            let separated = hunk.currentStart > 1
            if separated { start -= 1 }
            replacement = hunk.baseLines.isEmpty ? "" : (separated ? "\n" : "") + joined
        }
        return (NSRange(location: start, length: max(0, end - start)), replacement)
    }

    /// `text` split on `\n`, keeping the empty line a trailing newline opens,
    /// so numbering agrees with ``FilePreviewLineIndex``.
    static func lines(of text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }
}
