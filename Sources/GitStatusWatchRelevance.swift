import Foundation

/// Narrows a repository watch's coalesced filesystem batch to the paths that
/// can change `git status` for the watched working tree.
///
/// The Git-aware watch descriptor is tuned for the sidebar's branch display,
/// so its plan covers the common directory's `refs/`, `packed-refs`,
/// `reftable`, and the `FETCH_HEAD`-style files. A commit on another branch,
/// a fetch, or a `git gc` in any linked worktree writes those without
/// changing this working tree's status; both `git status` consumers (the
/// docked Changes panel and the file tree) used to refetch on each one.
///
/// Everything outside a `.git` directory is kept, as is the working tree's
/// own state under it: `index` and `index.lock`, `HEAD`, `MERGE_HEAD`,
/// `REBASE_HEAD` and the other in-progress operation files, and `config`.
/// A linked worktree's private directory (`.git/worktrees/<name>/`) is
/// judged by the same rule on its own contents, so its `index` and `HEAD`
/// still count while its `logs/` do not.
enum GitStatusWatchRelevance {
    /// Directories under `.git` whose contents never change `git status`
    /// output for the working tree: reference storage, the reflog, and the
    /// object database.
    private static let ignoredDirectories: Set<Substring> = ["refs", "logs", "objects"]

    /// Files under `.git` (with their `.lock`/`.new` siblings) that ref
    /// updates and fetches rewrite without affecting the working tree.
    private static let ignoredFilePrefixes = ["packed-refs", "reftable", "FETCH_HEAD", "ORIG_HEAD"]

    private static let gitDirectoryName = ".git"
    private static let linkedWorktreesDirectoryName = "worktrees"
    private static let separator = UInt8(ascii: "/")

    /// Whether one coalesced batch holds a change the watch must act on: a
    /// path that can change `git status` and that `isRelevant` (the watch
    /// descriptor's per-path rule) accepts. The scan stops at the first such
    /// path, and `isRelevant` is never asked about a path this filter drops.
    ///
    /// An empty batch keeps the descriptor's conservative answer for lost
    /// path detail; a batch made only of ignored paths is not a change.
    static func batchCanAffectStatus(_ paths: [String], isRelevant: (String) -> Bool) -> Bool {
        guard !paths.isEmpty else { return true }
        return paths.contains { canAffectStatus(path: $0) && isRelevant($0) }
    }

    /// Whether a change at `path` can alter `git status` output. Pure: the
    /// decision rests on the path's components after its last `.git`
    /// component, so both `/var` and `/private/var` spellings agree. The path
    /// is read in place, without splitting it into components: one backward
    /// scan finds the `.git` component, then only the component (or, inside
    /// `.git/worktrees/<name>/`, the worktree's own first component) after
    /// it is inspected.
    static func canAffectStatus(path: String) -> Bool {
        guard let gitDirectoryEnd = endOfLastGitComponent(in: path) else { return true }
        var cursor = gitDirectoryEnd
        guard var judged = nextComponent(in: path, from: &cursor) else { return true }
        if judged == linkedWorktreesDirectoryName {
            // `.git/worktrees/<name>/...`: judge the worktree's own contents.
            // `.git/worktrees` and `.git/worktrees/<name>` stay conservative.
            var lookahead = cursor
            if nextComponent(in: path, from: &lookahead) != nil,
               let contents = nextComponent(in: path, from: &lookahead) {
                judged = contents
            }
        }
        if ignoredDirectories.contains(judged) { return false }
        return !ignoredFilePrefixes.contains { judged.hasPrefix($0) }
    }

    /// The index just past the last `.git` component of `path` (the
    /// separator after it, or the end), or `nil` when no component is `.git`.
    /// Walks the components backwards, so `/a/.git/index` and `/a//.git/`
    /// agree and `.github` is never mistaken for `.git`.
    private static func endOfLastGitComponent(in path: String) -> String.Index? {
        let utf8 = path.utf8
        var end = utf8.endIndex
        while true {
            var start = end
            while start > utf8.startIndex, utf8[utf8.index(before: start)] != separator {
                start = utf8.index(before: start)
            }
            if utf8[start..<end].elementsEqual(gitDirectoryName.utf8) { return end }
            guard start > utf8.startIndex else { return nil }
            end = utf8.index(before: start)
        }
    }

    /// The next non-empty path component at or after `cursor`, leaving
    /// `cursor` just past it; `nil` once only separators remain.
    private static func nextComponent(in path: String, from cursor: inout String.Index) -> Substring? {
        let utf8 = path.utf8
        var start = cursor
        while start < utf8.endIndex, utf8[start] == separator {
            start = utf8.index(after: start)
        }
        guard start < utf8.endIndex else {
            cursor = start
            return nil
        }
        var end = start
        while end < utf8.endIndex, utf8[end] != separator {
            end = utf8.index(after: end)
        }
        cursor = end
        return path[start..<end]
    }
}
