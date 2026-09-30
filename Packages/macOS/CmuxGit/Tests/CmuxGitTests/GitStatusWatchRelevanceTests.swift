import Testing
@testable import CmuxGit

@Suite struct GitStatusWatchRelevanceTests {
    private let repo = "/Users/me/src/app"

    private func affects(_ relative: String) -> Bool {
        GitWorkspaceMetadataWatchDescriptor.canAffectStatus(path: "\(repo)/\(relative)")
    }

    /// A plan that follows the whole `.git` directory and one tracked file, like
    /// the sidebar's plan for a small repository.
    private func descriptor(
        gitMetadataPaths: [String]? = nil,
        trackedEntryPaths: [String] = []
    ) -> GitWorkspaceMetadataWatchDescriptor {
        GitWorkspaceMetadataWatchDescriptor(
            repositoryRoot: repo,
            watchedPaths: [repo],
            gitMetadataPaths: gitMetadataPaths ?? ["\(repo)/.git"],
            trackedEntryPaths: trackedEntryPaths.sorted(),
            acceptsAllWorkTreeEvents: false,
            eventCoalescingInterval: .milliseconds(100),
            eventFilterIdentity: nil
        )
    }

    @Test func workingTreeStateUnderGitDirectoryIsRelevant() {
        #expect(affects(".git/index"))
        #expect(affects(".git/index.lock"))
        #expect(affects(".git/HEAD"))
        #expect(affects(".git/MERGE_HEAD"))
        #expect(affects(".git/REBASE_HEAD"))
        #expect(affects(".git/rebase-merge/head-name"))
        #expect(affects(".git/config"))
        #expect(affects(".git"), "the gitdir pointer file of a linked worktree")
    }

    @Test func refObjectAndReflogChurnIsNotRelevant() {
        #expect(!affects(".git/refs/heads/feature"))
        #expect(!affects(".git/refs"))
        #expect(!affects(".git/packed-refs"))
        #expect(!affects(".git/packed-refs.lock"))
        #expect(!affects(".git/reftable/tables.list"))
        #expect(!affects(".git/FETCH_HEAD"))
        #expect(!affects(".git/ORIG_HEAD"))
        #expect(!affects(".git/logs/refs/heads/feature"))
        #expect(!affects(".git/logs/refs/remotes/origin/main"))
        #expect(!affects(".git/logs/refs/stash"))
        #expect(!affects(".git/logs"))
        #expect(!affects(".git/objects/ab/cd0123"))
    }

    /// `git reset --soft` and `git update-ref` on the checked-out branch move
    /// the commit HEAD resolves to without writing `HEAD`, the index or the
    /// working tree, yet `git status` (index against the new HEAD) changes.
    /// The files they do write are the branch ref, `ORIG_HEAD` and the
    /// reflogs; of those only HEAD's own reflog is written exactly when
    /// HEAD's target moves, so it is the signal. A linked worktree has its
    /// own HEAD and its own `logs/HEAD`.
    @Test func headReflogIsRelevant() {
        #expect(affects(".git/logs/HEAD"))
        #expect(affects(".git/worktrees/w/logs/HEAD"))
        #expect(!affects(".git/logs/HEADS"), "only the exact name")
        #expect(!affects(".git/logs/HEAD/x"), "a directory named HEAD under the reflog is not the reflog")
        #expect(!affects(".git/logs/refs/heads/main"), "a branch's reflog also moves for commits on other worktrees")
    }

    @Test func linkedWorktreePrivateDirectoryIsJudgedOnItsOwnContents() {
        #expect(affects(".git/worktrees/w/index"))
        #expect(affects(".git/worktrees/w/HEAD"))
        #expect(!affects(".git/worktrees/w/refs/x"))
        #expect(!affects(".git/worktrees/w/logs/refs/heads/x"))
        #expect(!affects(".git/worktrees/w/ORIG_HEAD"))
        #expect(affects(".git/worktrees/w"), "the worktree directory itself stays conservative")
        #expect(affects(".git/worktrees"))
    }

    @Test func pathsOutsideGitDirectoryAreRelevant() {
        #expect(affects("Sources/App.swift"))
        #expect(affects("refs/notes.txt"), "a tracked directory that happens to be named refs")
        #expect(affects(".github/workflows/ci.yml"))
        #expect(GitWorkspaceMetadataWatchDescriptor.canAffectStatus(path: repo))
    }

    @Test func pathSpellingsWithRepeatedOrTrailingSeparatorsAgree() {
        #expect(!GitWorkspaceMetadataWatchDescriptor.canAffectStatus(path: "\(repo)//.git//refs//heads/main"))
        #expect(!GitWorkspaceMetadataWatchDescriptor.canAffectStatus(path: "\(repo)/.git/refs/"))
        #expect(GitWorkspaceMetadataWatchDescriptor.canAffectStatus(path: "\(repo)/.git/"))
        #expect(GitWorkspaceMetadataWatchDescriptor.canAffectStatus(path: "\(repo)/.git/index/"))
        #expect(
            GitWorkspaceMetadataWatchDescriptor.canAffectStatus(path: ".git/index"),
            "a relative path with no leading separator"
        )
        #expect(!GitWorkspaceMetadataWatchDescriptor.canAffectStatus(path: ".git/objects/ab"))
        #expect(GitWorkspaceMetadataWatchDescriptor.canAffectStatus(path: ""))
    }

    @Test func onlyTheLastGitComponentDecides() {
        // The innermost `.git` decides, and a `.git` that is only part of a
        // component (`.github`, `my.git`, `.git-old`) is not one.
        #expect(GitWorkspaceMetadataWatchDescriptor.canAffectStatus(path: "\(repo)/.git/refs/inner/.git/index"))
        #expect(!GitWorkspaceMetadataWatchDescriptor.canAffectStatus(path: "\(repo)/.git/index/.git/objects/ab"))
        #expect(GitWorkspaceMetadataWatchDescriptor.canAffectStatus(path: "\(repo)/my.git/refs/heads/main"))
        #expect(GitWorkspaceMetadataWatchDescriptor.canAffectStatus(path: "\(repo)/.gitmodules"))
        #expect(GitWorkspaceMetadataWatchDescriptor.canAffectStatus(path: "\(repo)/.git-old/refs/x"))
    }

    @Test func perPathStatusRelevanceNeedsBothTheStatusRuleAndThePlan() {
        let plan = descriptor(trackedEntryPaths: ["\(repo)/README.md"])
        #expect(plan.containsStatusRelevantChange(path: "\(repo)/.git/index"))
        #expect(plan.containsStatusRelevantChange(path: "\(repo)/README.md"))
        #expect(
            !plan.containsStatusRelevantChange(path: "\(repo)/.git/refs/heads/main"),
            "the plan follows refs for the branch display, but status does not"
        )
        #expect(plan.containsRelevantChange(path: "\(repo)/.git/refs/heads/main"))
        #expect(
            !plan.containsStatusRelevantChange(path: "\(repo)/Sources/App.swift"),
            "a path the status rule keeps is still subject to the plan"
        )
        #expect(GitWorkspaceMetadataWatchDescriptor.canAffectStatus(path: "\(repo)/Sources/App.swift"))
    }

    /// The production plan (``GitMetadataService/gitRepositoryMetadataWatchPaths``)
    /// names the metadata files it follows rather than the whole `.git`
    /// directory, so the status filter can only pass `logs/HEAD` when the
    /// plan lists it too.
    @Test func productionPlanFollowsHeadReflogButNotBranchReflogs() {
        let repository = ResolvedGitRepository(
            workTreeRoot: repo,
            gitDirectory: "\(repo)/.git",
            commonDirectory: "\(repo)/.git"
        )
        let metadataPaths = GitMetadataService.gitRepositoryMetadataWatchPaths(
            repository: repository,
            configPathsByRepository: [repo: []]
        )
        #expect(metadataPaths.contains("\(repo)/.git/logs/HEAD"))
        #expect(!metadataPaths.contains("\(repo)/.git/logs"))
        let plan = descriptor(gitMetadataPaths: metadataPaths)
        #expect(plan.containsStatusRelevantChange(path: "\(repo)/.git/logs/HEAD"))
        #expect(plan.containsStatusRelevantChange(path: "\(repo)/.git/index"))
        #expect(!plan.containsStatusRelevantChange(path: "\(repo)/.git/logs/refs/heads/main"))
        #expect(!plan.containsStatusRelevantChange(path: "\(repo)/.git/refs/heads/main"))

        let linked = ResolvedGitRepository(
            workTreeRoot: "/Users/me/src/app-w",
            gitDirectory: "\(repo)/.git/worktrees/w",
            commonDirectory: "\(repo)/.git"
        )
        let linkedPaths = GitMetadataService.gitRepositoryMetadataWatchPaths(
            repository: linked,
            configPathsByRepository: [linked.workTreeRoot: []]
        )
        #expect(linkedPaths.contains("\(repo)/.git/worktrees/w/logs/HEAD"))
        #expect(!linkedPaths.contains("\(repo)/.git/logs/HEAD"), "the main worktree's HEAD is not this checkout's")
    }

    @Test func batchWithOneStatusRelevantPathIsAChange() {
        let plan = descriptor(trackedEntryPaths: ["\(repo)/README.md"])
        #expect(plan.containsStatusRelevantChange(paths: [
            "\(repo)/.git/refs/heads/main",
            "\(repo)/.git/logs/refs/heads/main",
            "\(repo)/README.md"
        ]))
        #expect(plan.containsStatusRelevantChange(paths: [
            "\(repo)/.git/refs/heads/main",
            "\(repo)/.git/logs/HEAD"
        ]), "a soft reset writes only refs and reflogs; HEAD's reflog carries it")
        #expect(plan.containsStatusRelevantChange(paths: [
            "\(repo)/.git/packed-refs",
            "\(repo)/.git/index",
            "\(repo)/README.md"
        ]))
    }

    @Test func batchOfOnlyIgnoredPathsIsNotAChange() {
        let plan = descriptor(trackedEntryPaths: ["\(repo)/README.md"])
        #expect(
            !plan.containsStatusRelevantChange(paths: ["\(repo)/.git/packed-refs", "\(repo)/.git/logs/refs/heads/main"]),
            "the plan would follow both, but neither can change status"
        )
        #expect(plan.containsRelevantChange(paths: ["\(repo)/.git/packed-refs", "\(repo)/.git/logs/refs/heads/main"]))
        let planWithoutGitDirectory = descriptor(gitMetadataPaths: [], trackedEntryPaths: ["\(repo)/README.md"])
        #expect(
            !planWithoutGitDirectory.containsStatusRelevantChange(paths: ["\(repo)/.git/index"]),
            "a status-relevant path the plan rejects is still not a change"
        )
    }

    @Test func emptyBatchAndLostPathHistoryKeepThePlansConservativeAnswer() {
        let plan = descriptor(trackedEntryPaths: ["\(repo)/README.md"])
        #expect(plan.containsStatusRelevantChange(paths: []))
        #expect(plan.containsStatusRelevantChange(paths: [], requiresFullRescan: true))
        #expect(
            plan.containsStatusRelevantChange(paths: ["\(repo)/.git/packed-refs"], requiresFullRescan: true),
            "lost path detail is a change even when the reported paths are ignored"
        )
    }

    @Test func forcedMetadataRuleSharesTheGitRelativeComponentHelper() {
        let plan = GitWorkspaceMetadataWatchDescriptor(
            repositoryRoot: repo,
            watchedPaths: [repo],
            gitMetadataPaths: [],
            trackedEntryPaths: [],
            forcedWorkTreeRoots: [repo],
            acceptsAllWorkTreeEvents: true,
            eventCoalescingInterval: .milliseconds(100),
            eventFilterIdentity: nil
        )
        #expect(plan.containsGitMetadataChange(paths: ["\(repo)/.git"]))
        #expect(plan.containsGitMetadataChange(paths: ["\(repo)/.git/"]))
        #expect(plan.containsGitMetadataChange(paths: ["\(repo)/.git/config"]))
        #expect(plan.containsGitMetadataChange(paths: ["\(repo)/.git/worktrees/w/HEAD"]))
        #expect(!plan.containsGitMetadataChange(paths: ["\(repo)/.git/objects/pack/a.pack"]))
        #expect(!plan.containsGitMetadataChange(paths: ["\(repo)/.git/modules/sub/logs/HEAD"]))
        #expect(!plan.containsGitMetadataChange(paths: ["\(repo)/.git/worktrees/w/logs/HEAD"]))
        #expect(!plan.containsGitMetadataChange(paths: ["\(repo)/Sources/App.swift"]))
        #expect(!plan.containsGitMetadataChange(paths: ["\(repo)/.github/workflows/ci.yml"]))
    }
}
