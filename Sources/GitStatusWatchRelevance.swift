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

    /// The paths of one batch that can change `git status`; order is kept.
    static func statusRelevantPaths(_ paths: [String]) -> [String] {
        paths.filter(canAffectStatus(path:))
    }

    /// Whether a change at `path` can alter `git status` output. Pure: the
    /// decision rests on the path's components after its last `.git`
    /// component, so both `/var` and `/private/var` spellings agree.
    static func canAffectStatus(path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let gitIndex = components.lastIndex(of: ".git") else { return true }
        var inside = components[(gitIndex + 1)...]
        if inside.first == "worktrees", inside.count >= 3 {
            // `.git/worktrees/<name>/...`: judge the worktree's own contents.
            inside = inside.dropFirst(2)
        }
        guard let first = inside.first else { return true }
        if ignoredDirectories.contains(first) { return false }
        return !ignoredFilePrefixes.contains { first.hasPrefix($0) }
    }
}
