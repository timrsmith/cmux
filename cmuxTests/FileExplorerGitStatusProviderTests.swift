import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct FileExplorerGitStatusProviderTests {
    @Test
    func statusQueryDoesNotRefreshGitIndex() throws {
        let repoURL = try GitRepositoryTestSupport.makeTemporaryDirectory(prefix: "cmux-file-explorer-git-status-")
        defer { try? FileManager.default.removeItem(at: repoURL) }

        try GitRepositoryTestSupport.initializeRepo(at: repoURL)

        let trackedURL = repoURL.appendingPathComponent("tracked.txt")
        try "one\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        try GitRepositoryTestSupport.runGit(["add", "tracked.txt"], in: repoURL)
        try GitRepositoryTestSupport.runGit(["commit", "-m", "initial"], in: repoURL)

        let indexURL = repoURL.appendingPathComponent(".git/index")
        let indexBeforeStatus = try Data(contentsOf: indexURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 10)],
            ofItemAtPath: trackedURL.path
        )

        _ = Self.fetchStatus(GitStatusProvider(), directory: repoURL.path)

        let indexAfterStatus = try Data(contentsOf: indexURL)
        #expect(indexAfterStatus == indexBeforeStatus)
    }

    @Test
    func statusQueryPreservesQuotedAndEscapedFilenames() throws {
        let repoURL = try GitRepositoryTestSupport.makeTemporaryDirectory(prefix: "cmux-file-explorer-git-status-")
        defer { try? FileManager.default.removeItem(at: repoURL) }
        try GitRepositoryTestSupport.initializeRepo(at: repoURL)

        let nestedURL = repoURL.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        let trackedURL = nestedURL.appendingPathComponent("quoted \"name\" and \\ slash.txt")
        try "one\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        try GitRepositoryTestSupport.runGit(["add", "."], in: repoURL)
        try GitRepositoryTestSupport.runGit(["commit", "-m", "initial"], in: repoURL)
        try "two\n".write(to: trackedURL, atomically: true, encoding: .utf8)

        let status = Self.fetchStatus(GitStatusProvider(), directory: nestedURL.path)

        #expect(status[trackedURL.path] == .some(.modified))
    }

    @Test
    func statusQueryExcludesSiblingPathPrefixes() throws {
        let repoURL = try GitRepositoryTestSupport.makeTemporaryDirectory(prefix: "cmux-file-explorer-git-status-")
        defer { try? FileManager.default.removeItem(at: repoURL) }
        try GitRepositoryTestSupport.initializeRepo(at: repoURL)

        let explorerRootURL = repoURL.appendingPathComponent("work", isDirectory: true)
        let siblingURL = repoURL.appendingPathComponent("workspace-sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: explorerRootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingURL, withIntermediateDirectories: true)

        let visibleURL = explorerRootURL.appendingPathComponent("tracked.txt")
        let siblingFileURL = siblingURL.appendingPathComponent("tracked.txt")
        try "one\n".write(to: visibleURL, atomically: true, encoding: .utf8)
        try "one\n".write(to: siblingFileURL, atomically: true, encoding: .utf8)
        try GitRepositoryTestSupport.runGit(["add", "."], in: repoURL)
        try GitRepositoryTestSupport.runGit(["commit", "-m", "initial"], in: repoURL)
        try "two\n".write(to: visibleURL, atomically: true, encoding: .utf8)
        try "two\n".write(to: siblingFileURL, atomically: true, encoding: .utf8)

        let status = Self.fetchStatus(GitStatusProvider(), directory: explorerRootURL.path)

        #expect(status[visibleURL.path] == .some(.modified))
        #expect(status[siblingFileURL.path] == nil)
        #expect(status[siblingURL.path] == nil)
    }

    @Test
    func statusQueryMapsTypeChangedAndUnmergedEntries() throws {
        let repoURL = try GitRepositoryTestSupport.makeTemporaryDirectory(prefix: "cmux-file-explorer-git-status-")
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let fakeGitURL = try Self.writeExecutableScript(
            #"""
            #!/bin/sh
            if [ "${CMUX_TEST_GIT_ENV:-}" != "expected" ]; then
                exit 3
            fi
            if [ "${GIT_OPTIONAL_LOCKS:-}" != "0" ]; then
                exit 4
            fi
            case "$1 $2" in
            "rev-parse --show-toplevel")
                printf '%s\n' "$CMUX_TEST_REPO_ROOT"
                ;;
            "status --porcelain=v1")
                printf ' T type-change.txt\0UU conflicted.txt\0'
                ;;
            *)
                exit 2
                ;;
            esac
            """#,
            named: "fake-git",
            in: repoURL
        )
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_TEST_GIT_ENV"] = "expected"
        environment["CMUX_TEST_REPO_ROOT"] = repoURL.path

        let status = Self.fetchStatus(
            GitStatusProvider(gitExecutableURL: fakeGitURL, environment: environment),
            directory: repoURL.path
        )

        #expect(
            status[repoURL.appendingPathComponent("type-change.txt").path] == .some(.modified)
        )
        #expect(
            status[repoURL.appendingPathComponent("conflicted.txt").path] == .some(.modified)
        )
    }

    @Test
    func sshStatusQueryUsesInjectedProcessEnvironment() throws {
        let repoURL = try GitRepositoryTestSupport.makeTemporaryDirectory(prefix: "cmux-file-explorer-git-status-")
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let fakeSSHURL = try Self.writeExecutableScript(
            #"""
            #!/bin/sh
            if [ "${CMUX_TEST_SSH_ENV:-}" != "expected" ]; then
                exit 3
            fi
            printf '%s\n---GIT_STATUS---\n M remote.txt\0' "$CMUX_TEST_REPO_ROOT"
            """#,
            named: "fake-ssh",
            in: repoURL
        )
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_TEST_REPO_ROOT"] = repoURL.path
        environment["CMUX_TEST_SSH_ENV"] = "expected"

        let status = Self.fetchStatusSSH(
            GitStatusProvider(sshExecutableURL: fakeSSHURL, environment: environment),
            directory: repoURL.path
        )

        #expect(
            status[repoURL.appendingPathComponent("remote.txt").path] == .some(.modified)
        )
    }

    @Test
    func sshStatusQueryOverridesHostConfiguredRemoteCommand() throws {
        // The remote git status runs as an ssh command-line command, which
        // OpenSSH refuses while a host-configured RemoteCommand is in effect
        // (issue #7246) — the argv must carry `-o RemoteCommand=none` before
        // the destination.
        let repoURL = try GitRepositoryTestSupport.makeTemporaryDirectory(prefix: "cmux-file-explorer-git-status-")
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let argvLog = repoURL.appendingPathComponent("ssh-argv.txt")
        let fakeSSHURL = try Self.writeExecutableScript(
            #"""
            #!/bin/sh
            for arg in "$@"; do printf '%s\n' "$arg"; done > "$CMUX_TEST_SSH_ARGV_LOG"
            printf '%s\n---GIT_STATUS---\n M remote.txt\0' "$CMUX_TEST_REPO_ROOT"
            """#,
            named: "fake-ssh",
            in: repoURL
        )
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_TEST_REPO_ROOT"] = repoURL.path
        environment["CMUX_TEST_SSH_ARGV_LOG"] = argvLog.path

        let status = Self.fetchStatusSSH(
            GitStatusProvider(sshExecutableURL: fakeSSHURL, environment: environment),
            directory: repoURL.path
        )

        #expect(
            status[repoURL.appendingPathComponent("remote.txt").path] == .some(.modified)
        )
        let argv = try String(contentsOf: argvLog, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let overrideIndex = argv.indices.dropLast().first {
            argv[$0] == "-o" && argv[$0 + 1] == "RemoteCommand=none"
        }
        let destinationIndex = argv.firstIndex(of: "example.invalid")
        #expect(overrideIndex != nil, "\(argv)")
        #expect(destinationIndex != nil, "\(argv)")
        if let overrideIndex, let destinationIndex {
            #expect(overrideIndex < destinationIndex)
        }
    }

    // MARK: - Nested repositories

    @Test
    func nestedRepositoryUnderNonRepoRootIsDiscoveredAndKeyedUnderExplorerRoot() throws {
        // explorerRoot (not a repo) / projects / repo (a repo) / tracked.txt
        let explorerRootURL = try GitRepositoryTestSupport.makeTemporaryDirectory(prefix: "cmux-file-explorer-git-status-")
        defer { try? FileManager.default.removeItem(at: explorerRootURL) }
        let projectsURL = explorerRootURL.appendingPathComponent("projects", isDirectory: true)
        let repoURL = projectsURL.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try GitRepositoryTestSupport.initializeRepo(at: repoURL)

        let trackedURL = repoURL.appendingPathComponent("tracked.txt")
        try "one\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        try GitRepositoryTestSupport.runGit(["add", "tracked.txt"], in: repoURL)
        try GitRepositoryTestSupport.runGit(["commit", "-m", "initial"], in: repoURL)
        try "two\n".write(to: trackedURL, atomically: true, encoding: .utf8)

        let provider = GitStatusProvider()

        // The explorer root is outside any repository, so nothing resolves there...
        #expect(provider.repositoryRoot(for: explorerRootURL.path) == nil)

        // ...while the nested directory resolves to its canonical repository root.
        let repoRoot = try #require(provider.repositoryRoot(for: repoURL.path))
        #expect(repoRoot == repoURL.resolvingSymlinksInPath().path)

        // Fetched against the explorer root, keys use the explorer's spelling and
        // the parent marks walk past the repo root up to the explorer root.
        let status = provider.fetchSnapshot(
            repoRoot: repoRoot,
            explorerRoot: GitStatusProvider.canonicalPath(explorerRootURL.path),
            keyRoot: explorerRootURL.path
        ).statusByPath
        #expect(status[trackedURL.path] == .some(.modified))
        #expect(status[repoURL.path] == .some(.modified))
        #expect(status[projectsURL.path] == .some(.modified))
        #expect(status[explorerRootURL.path] == nil)
    }

    @Test
    func deletedTrackedFilesYieldDeletedStatusAndGhostGrouping() throws {
        let repoURL = try GitRepositoryTestSupport.makeTemporaryDirectory(prefix: "cmux-file-explorer-git-status-")
        defer { try? FileManager.default.removeItem(at: repoURL) }
        try GitRepositoryTestSupport.initializeRepo(at: repoURL)

        let nestedURL = repoURL.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        let workTreeDeletedURL = repoURL.appendingPathComponent("worktree-deleted.txt")
        let stagedDeletedURL = repoURL.appendingPathComponent("staged-deleted.txt")
        let nestedDeletedURL = nestedURL.appendingPathComponent("nested-deleted.txt")
        let keptURL = repoURL.appendingPathComponent("kept.txt")
        for url in [workTreeDeletedURL, stagedDeletedURL, nestedDeletedURL, keptURL] {
            try "one\n".write(to: url, atomically: true, encoding: .utf8)
        }
        try GitRepositoryTestSupport.runGit(["add", "."], in: repoURL)
        try GitRepositoryTestSupport.runGit(["commit", "-m", "initial"], in: repoURL)

        // " D": deleted in the work tree only.
        try FileManager.default.removeItem(at: workTreeDeletedURL)
        try FileManager.default.removeItem(at: nestedDeletedURL)
        // "D ": deletion staged in the index.
        try GitRepositoryTestSupport.runGit(["rm", "-q", "staged-deleted.txt"], in: repoURL)

        let snapshot = try #require(Self.fetchSnapshot(GitStatusProvider(), directory: repoURL.path))

        #expect(snapshot.statusByPath[workTreeDeletedURL.path] == .some(.deleted))
        #expect(snapshot.statusByPath[stagedDeletedURL.path] == .some(.deleted))
        #expect(snapshot.statusByPath[nestedDeletedURL.path] == .some(.deleted))
        #expect(snapshot.statusByPath[nestedURL.path] == .some(.modified))
        #expect(snapshot.statusByPath[keptURL.path] == nil)

        #expect(
            snapshot.deletedPathsByParent[repoURL.path] ==
                [stagedDeletedURL.path, workTreeDeletedURL.path].sorted()
        )
        #expect(snapshot.deletedPathsByParent[nestedURL.path] == [nestedDeletedURL.path])
        #expect(snapshot.deletedPathsByParent.count == 2)
    }

    // MARK: - Helpers

    /// The store's local two-step fetch (resolve the repository, then fetch it
    /// against the canonical root) with keys spelled under `directory`, or `nil`
    /// when `directory` is not inside a repository.
    private static func fetchSnapshot(_ provider: GitStatusProvider, directory: String) -> GitStatusSnapshot? {
        guard let repoRoot = provider.repositoryRoot(for: directory) else { return nil }
        return provider.fetchSnapshot(
            repoRoot: repoRoot,
            explorerRoot: GitStatusProvider.canonicalPath(directory),
            keyRoot: directory
        )
    }

    private static func fetchStatus(_ provider: GitStatusProvider, directory: String) -> [String: GitFileStatus] {
        fetchSnapshot(provider, directory: directory)?.statusByPath ?? [:]
    }

    /// The store's SSH fetch against a fake `ssh` executable, keyed under `directory`.
    private static func fetchStatusSSH(_ provider: GitStatusProvider, directory: String) -> [String: GitFileStatus] {
        provider.fetchRepositoryStatusSSH(
            directory: directory,
            explorerRoot: directory,
            destination: "example.invalid",
            port: nil,
            identityFile: nil,
            sshOptions: []
        )?.snapshot.statusByPath ?? [:]
    }

    private static func writeExecutableScript(
        _ contents: String, named name: String, in directory: URL
    ) throws -> URL {
        let scriptURL = directory.appendingPathComponent(name)
        try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }
}
