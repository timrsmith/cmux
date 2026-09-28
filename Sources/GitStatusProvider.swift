import CmuxFoundation
import Foundation

/// Runs non-locking `git status --porcelain` and parses results into a path-to-status map.
///
/// The provider distinguishes three path spaces:
/// - `repoRoot`: where git runs and the base for the relative paths it prints.
/// - `explorerRoot`: the canonical spelling of the explorer root, used only for
///   the containment check (git prints physical paths such as `/private/var/...`).
/// - `keyRoot`: the caller's spelling of the explorer root; every emitted key is
///   re-spelled under it so `FileExplorerStore` lookups match its node paths.
struct GitStatusProvider: Sendable {
    private static let nonLockingGitEnvironmentKey = "GIT_OPTIONAL_LOCKS"
    private static let nonLockingGitEnvironmentValue = "0"
    /// Per-invocation config overrides that keep a browsed repository's own
    /// configuration from running code on our behalf. Nested-repository
    /// discovery runs git inside any folder the user expands, including an
    /// untrusted clone, whose `core.fsmonitor` may name an arbitrary command
    /// that `git status` would otherwise execute. Hooks are disabled for the
    /// same reason even though `status` and `rev-parse` run none today.
    /// `-c` flags must precede the subcommand.
    static let untrustedRepositoryGuardArguments = [
        "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null"
    ]
    private static let nonLockingRemoteGitCommand =
        "env \(nonLockingGitEnvironmentKey)=\(nonLockingGitEnvironmentValue) git "
        + untrustedRepositoryGuardArguments.joined(separator: " ")

    /// Upper bound on one local git run. A hung `git status` (a wedged
    /// filesystem, a stuck fsmonitor) would otherwise pin the store's
    /// per-repository in-flight token forever, so the repository would never
    /// refetch; on expiry the process is terminated and the run reports `nil`.
    static let defaultLocalTimeout: TimeInterval = 30
    /// Upper bound on one SSH round trip (connect plus the remote git run).
    static let defaultSSHTimeout: TimeInterval = 60

    private let gitExecutableURL: URL
    private let sshExecutableURL: URL
    private let environment: [String: String]
    private let localTimeout: TimeInterval
    private let sshTimeout: TimeInterval

    init(
        gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        sshExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        localTimeout: TimeInterval = GitStatusProvider.defaultLocalTimeout,
        sshTimeout: TimeInterval = GitStatusProvider.defaultSSHTimeout
    ) {
        self.gitExecutableURL = gitExecutableURL
        self.sshExecutableURL = sshExecutableURL
        self.environment = environment
        self.localTimeout = localTimeout
        self.sshTimeout = sshTimeout
    }

    // MARK: - Local

    /// The canonical working-tree root of the repository containing `directory`,
    /// or `nil` when the directory is not inside a repository.
    func repositoryRoot(for directory: String) -> String? {
        guard let root = gitRepoRoot(for: directory), !root.isEmpty else { return nil }
        return Self.canonicalPath(root)
    }

    /// Snapshot for one already-resolved repository.
    ///
    /// - Parameters:
    ///   - repoRoot: The canonical repository working-tree root from
    ///     ``repositoryRoot(for:)``; git runs here and prints paths below it.
    ///   - explorerRoot: The canonical spelling of the explorer root (see
    ///     ``canonicalPath(_:)``), compared against the paths git prints for the
    ///     containment check. Parent-directory marks walk up to this root, so a
    ///     repository nested below it marks every intermediate directory.
    ///   - keyRoot: The spelling emitted keys are re-based on (the store's `rootPath`).
    func fetchSnapshot(repoRoot: String, explorerRoot: String, keyRoot: String) -> GitStatusSnapshot {
        parseGitStatus(
            output: runGit(in: repoRoot, arguments: ["status", "--porcelain=v1", "-z"]),
            repoRoot: repoRoot,
            explorerRoot: explorerRoot,
            keyRoot: keyRoot
        )
    }

    // MARK: - SSH

    /// Resolves and fetches the remote repository containing `directory` in one
    /// round trip. Keys are emitted under `explorerRoot`, which must contain
    /// `directory`. Returns `nil` when the directory is not inside a repository or
    /// the SSH command failed.
    func fetchRepositoryStatusSSH(
        directory: String, explorerRoot: String, destination: String, port: Int?,
        identityFile: String?, sshOptions: [String]
    ) -> GitRepositoryStatus? {
        let escapedDir = directory.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = [
            "cd '\(escapedDir)' 2>/dev/null",
            "\(Self.nonLockingRemoteGitCommand) rev-parse --show-toplevel 2>/dev/null",
            "echo '---GIT_STATUS---'",
            "\(Self.nonLockingRemoteGitCommand) status --porcelain=v1 -z 2>/dev/null",
        ].joined(separator: " && ")
        guard let output = runSSH(
            command: cmd, destination: destination,
            port: port, identityFile: identityFile, sshOptions: sshOptions
        ) else { return nil }

        let parts = output.components(separatedBy: "---GIT_STATUS---\n")
        guard parts.count == 2 else { return nil }
        let repoRoot = parts[0].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !repoRoot.isEmpty else { return nil }
        // Remote paths must not be resolved against the local filesystem, so the comparison
        // space and the key space are both the caller's spelling here.
        let snapshot = parseGitStatus(
            output: parts[1], repoRoot: repoRoot, explorerRoot: explorerRoot, keyRoot: explorerRoot
        )
        return GitRepositoryStatus(repoRoot: repoRoot, snapshot: snapshot)
    }

    // MARK: - Parsing

    private func parseGitStatus(
        output: String?, repoRoot: String, explorerRoot: String, keyRoot: String
    ) -> GitStatusSnapshot {
        guard let output, !output.isEmpty else { return .empty }
        var statusMap: [String: GitFileStatus] = [:]
        var deletedByParent: [String: Set<String>] = [:]
        let normalizedRepoRoot = Self.pathWithoutTrailingSlashes(repoRoot)
        let normalizedExplorerRoot = Self.pathWithoutTrailingSlashes(explorerRoot)
        let normalizedKeyRoot = Self.pathWithoutTrailingSlashes(keyRoot)
        let entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)

        var entryIndex = 0
        while entryIndex < entries.count {
            let entry = entries[entryIndex]
            guard entry.count >= 4 else {
                entryIndex += 1
                continue
            }
            let indexStatus = entry[entry.startIndex]
            let workTreeStatus = entry[entry.index(after: entry.startIndex)]
            // git prints an untracked directory as `?? dir/`; the slash would
            // otherwise leave the directory row unkeyed and start the parent
            // marks one level too high.
            let path = Self.pathWithoutTrailingSlashes(String(entry.dropFirst(3)))
            let usesSecondPath = Self.statusUsesSecondPath(index: indexStatus, workTree: workTreeStatus)
            entryIndex += usesSecondPath ? 2 : 1
            guard let status = parseStatusChars(index: indexStatus, workTree: workTreeStatus) else { continue }

            let absolutePath = Self.absolutePath(repoRoot: normalizedRepoRoot, relativePath: path)
            guard Self.path(absolutePath, isContainedIn: normalizedExplorerRoot) else { continue }
            // Re-spell the key under the caller's root. When the two roots already match
            // (the common case) the path is used as-is. The root == "/" branch is reached
            // when the caller's root is a symlink to "/" (the canonical root is "/" while
            // keyRoot is not) and keeps the leading slash that dropFirst would otherwise eat.
            let key: String
            if normalizedKeyRoot == normalizedExplorerRoot {
                key = absolutePath
            } else if normalizedExplorerRoot == "/" {
                key = normalizedKeyRoot + absolutePath
            } else {
                key = normalizedKeyRoot + String(absolutePath.dropFirst(normalizedExplorerRoot.count))
            }

            statusMap[key] = status
            if indexStatus == "D" || workTreeStatus == "D" {
                let parent = (key as NSString).deletingLastPathComponent
                deletedByParent[parent, default: []].insert(key)
            }
            markParentDirectories(
                absolutePath: key,
                explorerRoot: normalizedKeyRoot,
                status: status,
                in: &statusMap
            )
        }
        return GitStatusSnapshot(
            statusByPath: statusMap,
            deletedPathsByParent: deletedByParent.mapValues { $0.sorted() }
        )
    }

    private func parseStatusChars(index: Character, workTree: Character) -> GitFileStatus? {
        if index == "?" && workTree == "?" { return .untracked }
        if index == "U" || workTree == "U" { return .modified }
        if index == "T" || workTree == "T" { return .modified }
        if index == "A" || workTree == "A" { return .added }
        if index == "C" || workTree == "C" { return .added }
        if index == "D" || workTree == "D" { return .deleted }
        if index == "R" || workTree == "R" { return .renamed }
        if index == "M" || workTree == "M" { return .modified }
        return nil
    }

    /// Marks every directory between the changed file and the explorer root
    /// (exclusive). The walk deliberately continues past the repository root so a
    /// repository nested below the explorer root colors its ancestors too.
    private func markParentDirectories(
        absolutePath: String, explorerRoot: String,
        status: GitFileStatus, in map: inout [String: GitFileStatus]
    ) {
        let dirStatus: GitFileStatus = (status == .untracked) ? .untracked : .modified
        var current = (absolutePath as NSString).deletingLastPathComponent
        while Self.path(current, isContainedIn: explorerRoot) && current != explorerRoot {
            if map[current] == nil {
                map[current] = dirStatus
            }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    private static func statusUsesSecondPath(index: Character, workTree: Character) -> Bool {
        index == "R" || workTree == "R" || index == "C" || workTree == "C"
    }

    /// The physical spelling of a local path (symlinks resolved), the space git
    /// prints paths in. Callers resolve their explorer root once and pass it to
    /// ``fetchSnapshot(repoRoot:explorerRoot:keyRoot:)`` for every fetch.
    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func absolutePath(repoRoot: String, relativePath: String) -> String {
        repoRoot == "/" ? "/" + relativePath : repoRoot + "/" + relativePath
    }

    /// Whether `path` is `root` or lies below it (both compared without
    /// trailing slashes). Shared with the store's nested-repository checks.
    static func path(_ path: String, isContainedIn root: String) -> Bool {
        let normalizedPath = pathWithoutTrailingSlashes(path)
        let normalizedRoot = pathWithoutTrailingSlashes(root)
        if normalizedPath == normalizedRoot { return true }
        if normalizedRoot == "/" { return normalizedPath.hasPrefix("/") }
        return normalizedPath.hasPrefix(normalizedRoot + "/")
    }

    /// `path` without redundant trailing slashes (`"/"` stays `"/"`): the key
    /// spelling shared by the parser and the store's per-directory indexes.
    static func pathWithoutTrailingSlashes(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private func gitRepoRoot(for directory: String) -> String? {
        runGit(in: directory, arguments: ["rev-parse", "--show-toplevel"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runGit(in directory: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = gitExecutableURL
        process.arguments = Self.untrustedRepositoryGuardArguments + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = nonLockingGitEnvironment()
        return Self.runCapturingStandardOutput(process, timeout: localTimeout)
    }

    private func nonLockingGitEnvironment() -> [String: String] {
        var environment = environment
        environment[Self.nonLockingGitEnvironmentKey] = Self.nonLockingGitEnvironmentValue
        return environment
    }

    private func runSSH(
        command: String, destination: String,
        port: Int?, identityFile: String?, sshOptions: [String]
    ) -> String? {
        let process = Process()
        process.executableURL = sshExecutableURL
        // The positional command conflicts with a host-configured
        // RemoteCommand unless overridden (issue #7246).
        var args: [String] = SSHHostConfiguredRemoteCommand().overrideArguments
        if let port { args += ["-p", String(port)] }
        if let identityFile { args += ["-i", identityFile] }
        for option in sshOptions { args += ["-o", option] }
        args += ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-T"]
        // Forwarding stays as configured: without `ControlMaster=no` this run
        // can become the shared master that interactive sessions reuse.
        args += ["--", destination, command]
        process.arguments = args
        process.environment = environment
        return Self.runCapturingStandardOutput(process, timeout: sshTimeout)
    }

    /// Runs `process` and returns its standard output when it exits 0 within
    /// `timeout`. On expiry the process is terminated (SIGTERM, then SIGKILL
    /// if it lingers) and the result is `nil`, so a caller never blocks on a
    /// hung child and the store's in-flight token is released like any other
    /// failed run. Standard error is discarded.
    private static func runCapturingStandardOutput(_ process: Process, timeout: TimeInterval) -> String? {
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exited = DispatchGroup()
        exited.enter()
        process.terminationHandler = { _ in exited.leave() }
        do {
            try process.run()
        } catch {
            exited.leave()
            return nil
        }
        // Drain stdout off this thread so a child that fills the pipe cannot
        // deadlock against the exit wait, and so that wait can be bounded.
        let output = ProcessOutputBox()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
            drained.leave()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
            // A grandchild may still hold the pipe open; do not wait on it.
            _ = drained.wait(timeout: .now() + 1)
            return nil
        }
        // The pipe closes when its last writer exits; bound this too in case a
        // detached grandchild inherited it.
        guard drained.wait(timeout: .now() + timeout) == .success else { return nil }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: output.data, encoding: .utf8)
    }
}

/// Landing spot for a child's stdout: written by the drain thread, read only
/// after that thread has signalled completion through its `DispatchGroup`.
private final class ProcessOutputBox: @unchecked Sendable {
    var data = Data()
}
