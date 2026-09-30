extension GitWorkspaceMetadataWatchDescriptor {
    /// Directories under `.git` whose contents never change `git status`
    /// output for the working tree: reference storage, the reflog (except
    /// HEAD's own, see ``headReflogPath``), and the object database.
    private static let statusIgnoredDirectories: Set<Substring> = ["refs", "logs", "objects"]

    /// Files under `.git` (with their `.lock`/`.new` siblings) that ref
    /// updates and fetches rewrite without affecting the working tree.
    private static let statusIgnoredFilePrefixes = ["packed-refs", "reftable", "FETCH_HEAD", "ORIG_HEAD"]

    /// HEAD's reflog, the one file under `logs/` that changes status: `git
    /// reset --soft` and `git update-ref` on the checked-out branch move the
    /// commit HEAD resolves to without writing `HEAD`, the index or the
    /// working tree, and `git status` (index against the new HEAD) changes.
    /// They write the branch ref, `ORIG_HEAD` and reflogs, all of which other
    /// operations churn too; only `logs/HEAD` is appended exactly when this
    /// checkout's HEAD target moves. A linked worktree has its own.
    private static let headReflogPath: [Substring] = ["logs", "HEAD"]

    private static let linkedWorktreesDirectoryName = "worktrees"

    /// Returns whether a coalesced batch holds a change that can alter
    /// `git status` output for the watched working tree.
    ///
    /// The plan behind ``containsRelevantChange(paths:requiresFullRescan:)``
    /// is tuned for the sidebar's branch display, so it also follows the
    /// common directory's `refs/`, `packed-refs`, `reftable`, and the
    /// `FETCH_HEAD`-style files. A commit on another branch, a fetch, or a
    /// `git gc` in any linked worktree writes those without changing this
    /// working tree's status. This variant drops such paths first
    /// (``canAffectStatus(path:)``) and asks the plan only about the rest,
    /// stopping at the first path both accept. A batch made only of dropped
    /// or plan-rejected paths is not a change.
    ///
    /// The status rule keeps this checkout's `logs/HEAD` because a soft reset
    /// or `update-ref` on the checked-out branch changes status while writing
    /// nothing else the rule keeps; the plan lists that file for the same
    /// reason (`GitMetadataService.gitRepositoryMetadataWatchPaths`). The
    /// descriptor does not know the checked-out branch, so `refs/heads/<name>`
    /// stays dropped like every other ref; with the reflog disabled
    /// (`core.logAllRefUpdates=false`) such a reset is therefore not seen.
    ///
    /// Lost path history and an empty batch defer to the plan's conservative
    /// answer, which is `true`.
    ///
    /// ```swift
    /// let watcher = await RecursivePathWatcher(
    ///     paths: descriptor.watchedPaths,
    ///     eventFilter: { change in
    ///         descriptor.containsStatusRelevantChange(
    ///             paths: change.paths,
    ///             requiresFullRescan: change.requiresFullRescan
    ///         )
    ///     }
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - paths: Absolute paths from one bounded FSEvents batch.
    ///   - requiresFullRescan: Whether the event source lost path history.
    /// - Returns: `true` when a `git status` consumer must refetch.
    public func containsStatusRelevantChange(
        paths: [String],
        requiresFullRescan: Bool = false
    ) -> Bool {
        guard !requiresFullRescan, !paths.isEmpty else {
            return containsRelevantChange(paths: paths, requiresFullRescan: requiresFullRescan)
        }
        return paths.contains { containsStatusRelevantChange(path: $0) }
    }

    /// Returns whether one path can alter `git status` output and overlaps
    /// this plan's Git metadata or tracked content.
    ///
    /// The status rule (``canAffectStatus(path:)``) is checked first, so the
    /// plan is never consulted about ref, reflog, or object churn.
    ///
    /// - Parameter path: Absolute filesystem path reported by FSEvents.
    /// - Returns: `true` when both the status rule and
    ///   ``containsRelevantChange(path:)`` accept the path.
    public func containsStatusRelevantChange(path: String) -> Bool {
        Self.canAffectStatus(path: path) && containsRelevantChange(path: path)
    }

    /// Returns whether a change at `path` can alter `git status` output,
    /// independent of any watch plan.
    ///
    /// Everything outside a `.git` directory is kept, as is the working
    /// tree's own state under it: `index` and `index.lock`, `HEAD`,
    /// `MERGE_HEAD`, `REBASE_HEAD` and the other in-progress operation files,
    /// `config`, and HEAD's reflog `logs/HEAD` (``headReflogPath``: the one
    /// file a soft reset or `update-ref` on the checked-out branch writes
    /// that nothing else here catches). Reference storage (`refs/`,
    /// `packed-refs`, `reftable`), the rest of the reflog (`logs/refs/...`),
    /// the object database (`objects/`), `FETCH_HEAD` and `ORIG_HEAD` are
    /// dropped. A linked worktree's private directory
    /// (`.git/worktrees/<name>/`) is judged by the same rule on its own
    /// contents, so its `index`, `HEAD` and `logs/HEAD` count while its
    /// `logs/refs/` do not; `.git/worktrees` and `.git/worktrees/<name>`
    /// themselves stay conservative, as do `.git` itself and the empty path.
    ///
    /// The decision rests on the components after the path's last `.git`
    /// component, so `/var` and `/private/var` spellings agree and `.github`,
    /// `my.git`, or `.git-old` never match. The path is read in place: one
    /// backward scan finds `.git`, then only the component after it (or, inside
    /// `.git/worktrees/<name>/`, the worktree's own first component) is
    /// inspected, plus one more for `logs/HEAD`.
    ///
    /// - Parameter path: Absolute or relative filesystem path.
    /// - Returns: `false` only for paths that provably cannot change status.
    public static func canAffectStatus(path: String) -> Bool {
        guard let relative = GitDirectoryRelativePath(path: path) else { return true }
        var components = relative.makeIterator()
        guard var judged = components.next() else { return true }
        if judged == linkedWorktreesDirectoryName {
            // `.git/worktrees/<name>/...`: judge the worktree's own contents.
            var lookahead = components
            if lookahead.next() != nil, let contents = lookahead.next() {
                judged = contents
                components = lookahead
            }
        }
        if statusIgnoredDirectories.contains(judged) {
            return isHeadReflog(first: judged, rest: components)
        }
        return !statusIgnoredFilePrefixes.contains { judged.hasPrefix($0) }
    }

    /// Whether `first` and the remaining components spell exactly `logs/HEAD`
    /// (no further component: `logs/HEAD/x` would be a directory, not the log).
    private static func isHeadReflog(first: Substring, rest: GitDirectoryRelativePath.Iterator) -> Bool {
        var rest = rest
        return first == headReflogPath[0]
            && rest.next() == headReflogPath[1]
            && rest.next() == nil
    }
}
