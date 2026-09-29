import CryptoKit
import Foundation

/// A digest of everything the Changes panel's working-tree diff can depend on,
/// so a filesystem event only refreshes the page when the diff can differ.
///
/// The git-aware watcher is deliberately conservative: it fires for any write
/// under the repository's `.git` directory and, in a large repository, for
/// any write under the working tree. A repository whose linked worktrees are
/// busy (other sessions committing, fetching, checking out) therefore raises
/// a steady stream of events that leave the working-tree diff untouched. The
/// panel used to reload its whole document on each one, faster than a diff
/// could parse.
///
/// The digest covers `git status --porcelain=v2 -z` (index and HEAD object
/// ids and modes for every changed entry, the paths, the untracked set) plus
/// the size and modification time of each listed working-tree path, which is
/// what changes when an already-dirty file is edited again. Object writes,
/// ref updates on other branches, and other worktrees' indexes never appear.
struct RightSidebarChangesFingerprint: Sendable {
    /// Produces the digest for a repository root, or `nil` when it cannot be
    /// computed (the panel then refreshes, as before).
    typealias Producer = @Sendable (_ repoRoot: String) async -> String?

    private static let nonLockingGitEnvironment = ["GIT_OPTIONAL_LOCKS": "0"]

    private let gitExecutableURL: URL
    private let environment: [String: String]
    private let timeout: TimeInterval

    init(
        gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = GitStatusProvider.defaultLocalTimeout
    ) {
        self.gitExecutableURL = gitExecutableURL
        self.environment = environment
        self.timeout = timeout
    }

    /// The default producer: runs the digest off the main actor.
    static let defaultProducer: Producer = { repoRoot in
        await Task.detached(priority: .utility) {
            RightSidebarChangesFingerprint().fingerprint(repoRoot: repoRoot)
        }.value
    }

    /// Runs git and stats the listed paths. Synchronous; call off the main actor.
    func fingerprint(repoRoot: String) -> String? {
        let process = Process()
        process.executableURL = gitExecutableURL
        process.arguments = GitStatusProvider.untrustedRepositoryGuardArguments
            + ["status", "--porcelain=v2", "-z", "--untracked-files=normal"]
        process.currentDirectoryURL = URL(fileURLWithPath: repoRoot, isDirectory: true)
        process.environment = environment.merging(Self.nonLockingGitEnvironment) { _, nonLocking in nonLocking }
        guard let status = GitStatusProvider.runCapturingStandardOutputData(process, timeout: timeout) else {
            return nil
        }
        return Self.digest(porcelainV2: status, repoRoot: repoRoot)
    }

    /// The digest of one porcelain v2 listing and the current state of the
    /// working-tree paths it names. Pure apart from the `stat` calls.
    static func digest(porcelainV2 status: Data, repoRoot: String) -> String {
        var hasher = SHA256()
        hasher.update(data: status)
        for path in workingTreePaths(porcelainV2: status) {
            let absolute = (repoRoot as NSString).appendingPathComponent(path)
            var info = stat()
            guard lstat(absolute, &info) == 0 else {
                hasher.update(data: Data("\u{0}missing:\(path)".utf8))
                continue
            }
            let mtime = info.st_mtimespec
            hasher.update(data: Data("\u{0}\(path)\u{0}\(info.st_size)\u{0}\(mtime.tv_sec).\(mtime.tv_nsec)".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The working-tree paths a `--porcelain=v2 -z` listing names: ordinary
    /// (`1`), renamed or copied (`2`, whose original path follows in its own
    /// NUL-terminated field), unmerged (`u`), and untracked (`?`) entries.
    /// Ignored (`!`) entries and headers (`#`) name nothing to stat.
    static func workingTreePaths(porcelainV2 status: Data) -> [String] {
        let fields = status.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        var paths: [String] = []
        var index = 0
        while index < fields.count {
            let record = fields[index]
            index += 1
            guard let kind = record.first else { continue }
            switch kind {
            case "1":
                if let path = nthSpaceSeparatedTail(record, skipping: 8) { paths.append(path) }
            case "2":
                if let path = nthSpaceSeparatedTail(record, skipping: 9) { paths.append(path) }
                // The original path is the next field; it no longer exists
                // under that name, so nothing to stat.
                index += 1
            case "u":
                if let path = nthSpaceSeparatedTail(record, skipping: 10) { paths.append(path) }
            case "?":
                if let path = nthSpaceSeparatedTail(record, skipping: 1) { paths.append(path) }
            default:
                continue
            }
        }
        return paths
    }

    /// The remainder of `record` after `count` space-separated fields; paths
    /// may themselves contain spaces, so only the leading fields are split.
    private static func nthSpaceSeparatedTail(_ record: String, skipping count: Int) -> String? {
        var remainder = Substring(record)
        for _ in 0..<count {
            guard let space = remainder.firstIndex(of: " ") else { return nil }
            remainder = remainder[remainder.index(after: space)...]
        }
        return remainder.isEmpty ? nil : String(remainder)
    }
}
