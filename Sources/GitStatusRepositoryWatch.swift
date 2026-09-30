import CmuxFoundation
import CmuxGit
import Foundation

/// A live filesystem subscription on one local git repository, consumed by
/// `FileExplorerStore` to re-fetch that repository's status when it changes.
///
/// The production watch wraps a `RecursivePathWatcher` on the repository's
/// Git-aware watch descriptor (index, refs, config, tracked entries); tests
/// inject a factory that yields into a hand-driven stream instead.
struct GitStatusRepositoryWatch: Sendable {
    /// Yields once per coalesced change window that can affect git status.
    let events: AsyncStream<Void>
    /// Tears the underlying watcher down. Idempotent.
    let stop: @Sendable () async -> Void
}

/// Creates a ``GitStatusRepositoryWatch`` for a canonical local repository root,
/// or `nil` when the repository cannot be watched.
typealias GitStatusRepositoryWatchFactory = @Sendable (_ repoRoot: String) async -> GitStatusRepositoryWatch?

enum GitStatusRepositoryWatching {
    /// One shared descriptor reader so its watch-plan cache is reused across
    /// repositories and explorer stores.
    private static let gitMetadataService = GitMetadataService()

    /// The production factory: resolves the repository's Git-aware watch
    /// descriptor and installs a recursive watcher filtered to the paths that
    /// can change `git status` output. The descriptor's plan is the sidebar's
    /// (`SidebarGitMetadataService`), which also follows ref and packed-ref
    /// churn for the branch display; the status-scoped filter
    /// (`GitWorkspaceMetadataWatchDescriptor.containsStatusRelevantChange`)
    /// drops those first so a commit or fetch in another worktree does not
    /// refetch this one's status, while keeping this checkout's `logs/HEAD`
    /// so a soft reset (refs and reflogs only) still does.
    static let defaultFactory: GitStatusRepositoryWatchFactory = { repoRoot in
        guard let descriptor = await GitStatusRepositoryWatching.gitMetadataService.watchDescriptor(for: repoRoot) else { return nil }
        guard let watcher = await RecursivePathWatcher(
            paths: descriptor.watchedPaths,
            throttleInterval: descriptor.eventCoalescingInterval,
            eventFilter: { change in
                descriptor.containsStatusRelevantChange(
                    paths: change.paths,
                    requiresFullRescan: change.requiresFullRescan
                )
            }
        ) else { return nil }
        return GitStatusRepositoryWatch(
            events: watcher.events,
            stop: { await watcher.stop() }
        )
    }
}
