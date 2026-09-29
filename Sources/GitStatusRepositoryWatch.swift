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
    /// can change `git status` output. The descriptor's plan and relevance
    /// filter are the sidebar's (`SidebarGitMetadataService`), which also
    /// follow ref, packed-ref and reflog churn for the branch display;
    /// ``GitStatusWatchRelevance`` drops those first so a commit or fetch in
    /// another worktree does not refetch this one's status.
    static let defaultFactory: GitStatusRepositoryWatchFactory = { repoRoot in
        guard let descriptor = await GitStatusRepositoryWatching.gitMetadataService.watchDescriptor(for: repoRoot) else { return nil }
        guard let watcher = await RecursivePathWatcher(
            paths: descriptor.watchedPaths,
            throttleInterval: descriptor.eventCoalescingInterval,
            eventFilter: { change in
                // Lost path history keeps the descriptor's conservative answer.
                if change.requiresFullRescan {
                    return descriptor.containsRelevantChange(paths: change.paths, requiresFullRescan: true)
                }
                // Stops at the first path both filters accept; a batch made
                // only of ignored paths is not a change.
                return GitStatusWatchRelevance.batchCanAffectStatus(
                    change.paths,
                    isRelevant: descriptor.containsRelevantChange(path:)
                )
            }
        ) else { return nil }
        return GitStatusRepositoryWatch(
            events: watcher.events,
            stop: { await watcher.stop() }
        )
    }
}
