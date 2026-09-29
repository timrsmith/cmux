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

    func testBatchFilterKeepsOrderAndDropsOnlyIgnoredPaths() {
        let batch = [
            "\(repo)/.git/refs/heads/main",
            "\(repo)/.git/index",
            "\(repo)/.git/logs/HEAD",
            "\(repo)/README.md"
        ]
        XCTAssertEqual(
            GitStatusWatchRelevance.statusRelevantPaths(batch),
            ["\(repo)/.git/index", "\(repo)/README.md"]
        )
        XCTAssertEqual(GitStatusWatchRelevance.statusRelevantPaths(["\(repo)/.git/packed-refs"]), [])
        XCTAssertEqual(GitStatusWatchRelevance.statusRelevantPaths([]), [])
    }
}
