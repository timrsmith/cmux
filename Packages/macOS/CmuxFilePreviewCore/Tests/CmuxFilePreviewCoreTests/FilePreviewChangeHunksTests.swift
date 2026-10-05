import Foundation
import Testing

@testable import CmuxFilePreviewCore

@Suite("File Preview change hunks")
struct FilePreviewChangeHunksTests {
    private func revert(_ hunk: FilePreviewChangeHunk, in current: String) -> String {
        let edit = FilePreviewChangeHunks.revertEdit(for: hunk, in: current)
        return (current as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    @Test("Identical texts have no hunks")
    func identicalTexts() {
        #expect(FilePreviewChangeHunks(base: "a\nb\n", current: "a\nb\n").isEmpty)
        #expect(FilePreviewChangeHunks(base: "", current: "").isEmpty)
    }

    @Test("Added, deleted and modified lines become one hunk each with 1-based lines")
    func kindsAndLines() {
        let base = "one\ntwo\nthree\nfour\n"
        let current = "one\nTWO\nthree\nnew\nfour\n"
        let hunks = FilePreviewChangeHunks(base: base, current: current).hunks
        #expect(hunks.count == 2)
        #expect(hunks[0] == FilePreviewChangeHunk(baseStart: 2, baseCount: 1, currentStart: 2, currentCount: 1, baseLines: ["two"]))
        #expect(hunks[0].kind == .modified)
        #expect(hunks[1] == FilePreviewChangeHunk(baseStart: 4, baseCount: 0, currentStart: 4, currentCount: 1, baseLines: []))
        #expect(hunks[1].kind == .added)

        let deleted = FilePreviewChangeHunks(base: base, current: "one\nfour\n").hunks
        #expect(deleted == [FilePreviewChangeHunk(baseStart: 2, baseCount: 2, currentStart: 2, currentCount: 0, baseLines: ["two", "three"])])
        #expect(deleted[0].kind == .deleted)
        #expect(deleted[0].markerLine == 2)
    }

    @Test("Adjacent removals and insertions merge into a single modification")
    func mergesAdjacentChanges() {
        let hunks = FilePreviewChangeHunks(base: "a\nb\nc\nd\n", current: "a\nB1\nB2\nd\n").hunks
        #expect(hunks == [FilePreviewChangeHunk(baseStart: 2, baseCount: 2, currentStart: 2, currentCount: 2, baseLines: ["b", "c"])])
    }

    @Test("Marker lookup covers the hunk's lines, and a deletion only its line")
    func markerLookup() {
        // "b" and "c" vanish before "d"; "e" becomes "E" and gains "x" and
        // "y" right after it, which is one modification, not two hunks.
        let hunks = FilePreviewChangeHunks(base: "a\nb\nc\nd\ne\n", current: "a\nd\nE\nx\ny\n")
        #expect(hunks.hunks.count == 2)
        #expect(hunks.hunk(atCurrentLine: 2)?.kind == .deleted)
        #expect(hunks.hunk(atCurrentLine: 3)?.kind == .modified)
        #expect(hunks.hunk(atCurrentLine: 4)?.kind == .modified)
        #expect(hunks.hunk(atCurrentLine: 5)?.kind == .modified)
        #expect(hunks.hunk(atCurrentLine: 1) == nil)
        #expect(hunks.hunks(inCurrentLines: 4...5).count == 1)
        #expect(hunks.hunks(inCurrentLines: 2...2).count == 1)
        #expect(hunks.hunks(inCurrentLines: 1...1).isEmpty)

        let separate = FilePreviewChangeHunks(base: "a\nb\nc\n", current: "a\nb\nc\nx\n")
        #expect(separate.hunk(atCurrentLine: 4)?.kind == .added)
        #expect(separate.hunk(atCurrentLine: 3) == nil)
    }

    @Test("Reverting each hunk restores the base lines and keeps the rest")
    func revertRestoresBase() {
        let base = "one\ntwo\nthree\nfour\n"
        let current = "one\nTWO\nthree\nnew\nfour\n"
        let hunks = FilePreviewChangeHunks(base: base, current: current).hunks
        #expect(revert(hunks[0], in: current) == "one\ntwo\nthree\nnew\nfour\n")
        #expect(revert(hunks[1], in: current) == "one\nTWO\nthree\nfour\n")

        let deleted = FilePreviewChangeHunks(base: base, current: "one\nfour\n").hunks
        #expect(revert(deleted[0], in: "one\nfour\n") == base)
    }

    @Test("Reverting at the end of the file respects the trailing newline either way")
    func revertAtEndOfFile() {
        // The last line lost its newline: the hunk is the final empty line
        // becoming content; the revert puts the newline back.
        let unterminated = FilePreviewChangeHunks(base: "a\nb\n", current: "a\nb\nc").hunks
        #expect(unterminated.count == 1)
        #expect(revert(unterminated[0], in: "a\nb\nc") == "a\nb\n")

        // Base unterminated, current appends lines: the revert removes them
        // and leaves the file unterminated.
        let appended = FilePreviewChangeHunks(base: "a\nb", current: "a\nb\nc\nd").hunks
        #expect(revert(appended[0], in: "a\nb\nc\nd") == "a\nb")

        // Base had a trailing line that the current unterminated text lost.
        let trimmed = FilePreviewChangeHunks(base: "a\nb\nc", current: "a\nb").hunks
        #expect(trimmed.count == 1)
        #expect(revert(trimmed[0], in: "a\nb") == "a\nb\nc")
    }

    @Test("A wholly new file is one added hunk, and a cleared file one deletion")
    func wholeFile() {
        let added = FilePreviewChangeHunks(base: "", current: "x\ny\n").hunks
        #expect(added.count == 1)
        #expect(added[0].kind == .modified || added[0].kind == .added)
        #expect(revert(added[0], in: "x\ny\n") == "")

        let cleared = FilePreviewChangeHunks(base: "x\ny\n", current: "").hunks
        #expect(cleared.count == 1)
        #expect(revert(cleared[0], in: "") == "x\ny\n")
    }
}
