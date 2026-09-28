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
            while [ "$1" = "-c" ]; do shift 2; done
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

    @Test
    func untrackedDirectoryIsKeyedWithoutGitsTrailingSlash() throws {
        // git prints an untracked directory as `?? newdir/`. The row for the
        // directory itself must be colored, and its parent marks must start at
        // the directory's parent, not one level above.
        let repoURL = try GitRepositoryTestSupport.makeTemporaryDirectory(prefix: "cmux-file-explorer-git-status-")
        defer { try? FileManager.default.removeItem(at: repoURL) }
        try GitRepositoryTestSupport.initializeRepo(at: repoURL)
        try "one\n".write(to: repoURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try GitRepositoryTestSupport.runGit(["add", "."], in: repoURL)
        try GitRepositoryTestSupport.runGit(["commit", "-m", "initial"], in: repoURL)

        let outerURL = repoURL.appendingPathComponent("outer", isDirectory: true)
        let newDirURL = outerURL.appendingPathComponent("newdir", isDirectory: true)
        try FileManager.default.createDirectory(at: newDirURL, withIntermediateDirectories: true)
        try "new\n".write(to: newDirURL.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let status = Self.fetchStatus(GitStatusProvider(), directory: repoURL.path)

        // git collapses the whole untracked subtree into `?? outer/`.
        #expect(status[outerURL.path] == .some(.untracked))
        #expect(status[outerURL.path + "/"] == nil)
        #expect(status[repoURL.path] == nil)

        // With the intermediate directory known to git, the leaf directory is
        // the untracked entry and its parent is marked from it.
        try "keep\n".write(to: outerURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try GitRepositoryTestSupport.runGit(["add", "outer/tracked.txt"], in: repoURL)
        try GitRepositoryTestSupport.runGit(["commit", "-m", "outer"], in: repoURL)

        let nestedStatus = Self.fetchStatus(GitStatusProvider(), directory: repoURL.path)
        #expect(nestedStatus[newDirURL.path] == .some(.untracked))
        #expect(nestedStatus[newDirURL.path + "/"] == nil)
        #expect(nestedStatus[outerURL.path] == .some(.untracked))
    }

    @Test
    func renamedEntryConsumesBothPathsAndKeepsParsingLaterEntries() throws {
        // `R  new\0old\0` carries two NUL-terminated paths; the parser must skip
        // the original path instead of treating it as the next entry's header.
        let repoURL = try GitRepositoryTestSupport.makeTemporaryDirectory(prefix: "cmux-file-explorer-git-status-")
        defer { try? FileManager.default.removeItem(at: repoURL) }
        try GitRepositoryTestSupport.initializeRepo(at: repoURL)

        let oldURL = repoURL.appendingPathComponent("a.txt")
        let newURL = repoURL.appendingPathComponent("b.txt")
        let laterURL = repoURL.appendingPathComponent("z-later.txt")
        try "same\n".write(to: oldURL, atomically: true, encoding: .utf8)
        try "one\n".write(to: laterURL, atomically: true, encoding: .utf8)
        try GitRepositoryTestSupport.runGit(["add", "."], in: repoURL)
        try GitRepositoryTestSupport.runGit(["commit", "-m", "initial"], in: repoURL)
        try GitRepositoryTestSupport.runGit(["mv", "a.txt", "b.txt"], in: repoURL)
        try "two\n".write(to: laterURL, atomically: true, encoding: .utf8)

        let status = Self.fetchStatus(GitStatusProvider(), directory: repoURL.path)

        #expect(status[newURL.path] == .some(.renamed))
        #expect(status[oldURL.path] == nil)
        #expect(status[laterURL.path] == .some(.modified))
        #expect(status[repoURL.path] == nil)
    }

    @Test
    func localGitInvocationsDisableTheRepositorysFsmonitorAndHooks() throws {
        // Nested-repository discovery runs git inside whatever folder the user
        // expands, honoring that repository's config. An untrusted clone's
        // `core.fsmonitor` names a command `git status` would run, so every
        // local invocation overrides it (and the hooks path) with `-c` flags
        // placed before the subcommand.
        let repoURL = try GitRepositoryTestSupport.makeTemporaryDirectory(prefix: "cmux-file-explorer-git-status-")
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let argvLogDirectory = repoURL.appendingPathComponent("argv", isDirectory: true)
        try FileManager.default.createDirectory(at: argvLogDirectory, withIntermediateDirectories: true)
        let fakeGitURL = try Self.writeExecutableScript(
            #"""
            #!/bin/sh
            log="$CMUX_TEST_GIT_ARGV_DIR/$$.txt"
            for arg in "$@"; do printf '%s\n' "$arg"; done > "$log"
            while [ "$1" = "-c" ]; do shift 2; done
            case "$1" in
            rev-parse) printf '%s\n' "$CMUX_TEST_REPO_ROOT" ;;
            status) printf ' M tracked.txt\0' ;;
            *) exit 2 ;;
            esac
            """#,
            named: "fake-git",
            in: repoURL
        )
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_TEST_REPO_ROOT"] = repoURL.resolvingSymlinksInPath().path
        environment["CMUX_TEST_GIT_ARGV_DIR"] = argvLogDirectory.path

        let status = Self.fetchStatus(
            GitStatusProvider(gitExecutableURL: fakeGitURL, environment: environment),
            directory: repoURL.path
        )
        #expect(status[repoURL.appendingPathComponent("tracked.txt").path] == .some(.modified))

        let logs = try FileManager.default.contentsOfDirectory(atPath: argvLogDirectory.path)
        let invocations = try logs.map { name -> [String] in
            try String(contentsOf: argvLogDirectory.appendingPathComponent(name), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
        }
        #expect(invocations.count == 2, "\(invocations)")
        let subcommands = Set(invocations.compactMap { argv in argv.first { !$0.hasPrefix("-") && !$0.contains("=") } })
        #expect(subcommands == ["rev-parse", "status"], "\(invocations)")
        for argv in invocations {
            let guardFlags = Self.configFlags(in: argv)
            #expect(guardFlags.contains("core.fsmonitor=false"), "\(argv)")
            #expect(guardFlags.contains("core.hooksPath=/dev/null"), "\(argv)")
            // Every `-c` pair precedes the subcommand.
            let subcommandIndex = try #require(argv.firstIndex { $0 == "rev-parse" || $0 == "status" })
            let lastFlagIndex = try #require(argv.lastIndex(of: "-c"))
            #expect(lastFlagIndex + 1 < subcommandIndex, "\(argv)")
        }
    }

    @Test
    func sshGitCommandsDisableTheRepositorysFsmonitorAndHooks() throws {
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
        #expect(status[repoURL.appendingPathComponent("remote.txt").path] == .some(.modified))

        // The remote command is the last argument; both git runs in it carry the guards.
        let argv = try String(contentsOf: argvLog, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let remoteCommand = try #require(argv.last)
        let gitRuns = remoteCommand.components(separatedBy: " && ").filter { $0.contains(" git ") }
        #expect(gitRuns.count == 2, "\(remoteCommand)")
        for run in gitRuns {
            #expect(run.contains("git -c core.fsmonitor=false -c core.hooksPath=/dev/null "), "\(run)")
        }
        #expect(gitRuns.contains { $0.contains("core.hooksPath=/dev/null rev-parse --show-toplevel") }, "\(remoteCommand)")
        #expect(gitRuns.contains { $0.contains("core.hooksPath=/dev/null status --porcelain=v1 -z") }, "\(remoteCommand)")
    }

    @Test
    func hungGitRunIsTerminatedAtTheTimeoutAndReportsNoStatus() throws {
        // A `git status` that never exits must not pin the caller: the provider
        // terminates it at the deadline and reports an empty snapshot so the
        // store's in-flight token is released.
        let repoURL = try GitRepositoryTestSupport.makeTemporaryDirectory(prefix: "cmux-file-explorer-git-status-")
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let fakeGitURL = try Self.writeExecutableScript(
            #"""
            #!/bin/sh
            while [ "$1" = "-c" ]; do shift 2; done
            case "$1" in
            rev-parse) printf '%s\n' "$CMUX_TEST_REPO_ROOT" ;;
            status) exec sleep 20 ;;
            *) exit 2 ;;
            esac
            """#,
            named: "fake-git",
            in: repoURL
        )
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_TEST_REPO_ROOT"] = repoURL.resolvingSymlinksInPath().path

        let provider = GitStatusProvider(
            gitExecutableURL: fakeGitURL, environment: environment, localTimeout: 0.3
        )
        let repoRoot = try #require(provider.repositoryRoot(for: repoURL.path))

        let started = Date()
        let snapshot = provider.fetchSnapshot(
            repoRoot: repoRoot,
            explorerRoot: GitStatusProvider.canonicalPath(repoURL.path),
            keyRoot: repoURL.path
        )
        let elapsed = Date().timeIntervalSince(started)

        #expect(snapshot == .empty)
        #expect(elapsed < 5, "fetch took \(elapsed)s; the 0.3s timeout did not bound the hung run")
    }

    // MARK: - Helpers

    /// The values of every `-c key=value` pair in a git argv.
    private static func configFlags(in argv: [String]) -> [String] {
        argv.indices.dropLast().compactMap { argv[$0] == "-c" ? argv[$0 + 1] : nil }
    }

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
