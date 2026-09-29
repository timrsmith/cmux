import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class GitStatusWatchRelevanceTests: XCTestCase {
    private let repo = "/Users/me/src/app"

    private func affects(_ relative: String) -> Bool {
        GitStatusWatchRelevance.canAffectStatus(path: "\(repo)/\(relative)")
    }

    func testWorkingTreeStateUnderGitDirectoryIsRelevant() {
        XCTAssertTrue(affects(".git/index"))
        XCTAssertTrue(affects(".git/index.lock"))
        XCTAssertTrue(affects(".git/HEAD"))
        XCTAssertTrue(affects(".git/MERGE_HEAD"))
        XCTAssertTrue(affects(".git/REBASE_HEAD"))
        XCTAssertTrue(affects(".git/rebase-merge/head-name"))
        XCTAssertTrue(affects(".git/config"))
        XCTAssertTrue(affects(".git"), "the gitdir pointer file of a linked worktree")
    }

    func testRefObjectAndReflogChurnIsNotRelevant() {
        XCTAssertFalse(affects(".git/refs/heads/feature"))
        XCTAssertFalse(affects(".git/refs"))
        XCTAssertFalse(affects(".git/packed-refs"))
        XCTAssertFalse(affects(".git/packed-refs.lock"))
        XCTAssertFalse(affects(".git/reftable/tables.list"))
        XCTAssertFalse(affects(".git/FETCH_HEAD"))
        XCTAssertFalse(affects(".git/ORIG_HEAD"))
        XCTAssertFalse(affects(".git/logs/HEAD"))
        XCTAssertFalse(affects(".git/objects/ab/cd0123"))
    }

    func testLinkedWorktreePrivateDirectoryIsJudgedOnItsOwnContents() {
        XCTAssertTrue(affects(".git/worktrees/w/index"))
        XCTAssertTrue(affects(".git/worktrees/w/HEAD"))
        XCTAssertFalse(affects(".git/worktrees/w/refs/x"))
        XCTAssertFalse(affects(".git/worktrees/w/logs/HEAD"))
        XCTAssertFalse(affects(".git/worktrees/w/ORIG_HEAD"))
        XCTAssertTrue(affects(".git/worktrees/w"), "the worktree directory itself stays conservative")
        XCTAssertTrue(affects(".git/worktrees"))
    }

    func testPathsOutsideGitDirectoryAreRelevant() {
        XCTAssertTrue(affects("Sources/App.swift"))
        XCTAssertTrue(affects("refs/notes.txt"), "a tracked directory that happens to be named refs")
        XCTAssertTrue(affects(".github/workflows/ci.yml"))
        XCTAssertTrue(GitStatusWatchRelevance.canAffectStatus(path: repo))
    }

    func testBatchFilterAsksTheDescriptorOnlyAboutStatusRelevantPaths() {
        let batch = [
            "\(repo)/.git/refs/heads/main",
            "\(repo)/.git/index",
            "\(repo)/.git/logs/HEAD",
            "\(repo)/README.md"
        ]
        var asked: [String] = []
        XCTAssertTrue(GitStatusWatchRelevance.batchCanAffectStatus(batch) { path in
            asked.append(path)
            return path.hasSuffix("README.md")
        })
        XCTAssertEqual(
            asked,
            ["\(repo)/.git/index", "\(repo)/README.md"],
            "ignored paths never reach the descriptor; order is kept"
        )
    }

    func testBatchFilterStopsAtTheFirstRelevantPath() {
        let batch = ["\(repo)/.git/packed-refs", "\(repo)/.git/index", "\(repo)/README.md"]
        var asked: [String] = []
        XCTAssertTrue(GitStatusWatchRelevance.batchCanAffectStatus(batch) { path in
            asked.append(path)
            return true
        })
        XCTAssertEqual(asked, ["\(repo)/.git/index"], "the rest of the batch is not scanned once one path counts")
    }

    func testBatchOfOnlyIgnoredPathsIsNotAChangeAndSkipsTheDescriptor() {
        var askCount = 0
        XCTAssertFalse(
            GitStatusWatchRelevance.batchCanAffectStatus(["\(repo)/.git/packed-refs", "\(repo)/.git/logs/HEAD"]) { _ in
                askCount += 1
                return true
            }
        )
        XCTAssertEqual(askCount, 0)
        XCTAssertFalse(
            GitStatusWatchRelevance.batchCanAffectStatus(["\(repo)/.git/index"]) { _ in false },
            "a status-relevant path the descriptor rejects is still not a change"
        )
    }

    func testEmptyBatchKeepsTheDescriptorsConservativeAnswer() {
        var askCount = 0
        XCTAssertTrue(GitStatusWatchRelevance.batchCanAffectStatus([]) { _ in
            askCount += 1
            return false
        })
        XCTAssertEqual(askCount, 0)
    }

    func testPathSpellingsWithRepeatedOrTrailingSeparatorsAgree() {
        XCTAssertFalse(GitStatusWatchRelevance.canAffectStatus(path: "\(repo)//.git//refs//heads/main"))
        XCTAssertFalse(GitStatusWatchRelevance.canAffectStatus(path: "\(repo)/.git/refs/"))
        XCTAssertTrue(GitStatusWatchRelevance.canAffectStatus(path: "\(repo)/.git/"))
        XCTAssertTrue(GitStatusWatchRelevance.canAffectStatus(path: "\(repo)/.git/index/"))
        XCTAssertTrue(GitStatusWatchRelevance.canAffectStatus(path: ".git/index"), "a relative path with no leading separator")
        XCTAssertFalse(GitStatusWatchRelevance.canAffectStatus(path: ".git/objects/ab"))
        XCTAssertTrue(GitStatusWatchRelevance.canAffectStatus(path: ""))
    }

    func testOnlyTheLastGitComponentDecides() {
        // The innermost `.git` decides, and a `.git` that is only part of a
        // component (`.github`, `my.git`, `.git-old`) is not one.
        XCTAssertTrue(GitStatusWatchRelevance.canAffectStatus(path: "\(repo)/.git/refs/inner/.git/index"))
        XCTAssertFalse(GitStatusWatchRelevance.canAffectStatus(path: "\(repo)/.git/index/.git/objects/ab"))
        XCTAssertTrue(GitStatusWatchRelevance.canAffectStatus(path: "\(repo)/my.git/refs/heads/main"))
        XCTAssertTrue(GitStatusWatchRelevance.canAffectStatus(path: "\(repo)/.gitmodules"))
        XCTAssertTrue(GitStatusWatchRelevance.canAffectStatus(path: "\(repo)/.git-old/refs/x"))
    }
}
