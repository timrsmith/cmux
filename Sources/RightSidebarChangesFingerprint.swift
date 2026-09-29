import CryptoKit
import Foundation

/// A digest of everything the Changes panel's working-tree diff can depend on,
/// so a filesystem event only refreshes the page when the diff can differ.
///
/// The git-aware watcher fires for the repository's `HEAD`, `index`, `refs`,
/// `packed-refs`, `reftable` and `config` paths and for tracked entries (in a
/// large repository, for any write under the working tree). Ref, packed-ref
/// and reflog churn from other worktrees is dropped before it reaches the
/// store (``GitStatusWatchRelevance``), but the index is still rewritten
/// without the diff changing: another tool's `git status` refreshing the stat
/// cache, `git add` of an already-staged path, an editor saving a file with
/// identical contents. The panel used to reload its whole document on each
/// such event, faster than a diff could parse.
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

    /// Runs git with the same untrusted-repository guards, non-locking
    /// environment and timeout as the file tree's status fetch.
    private let gitStatusProvider: GitStatusProvider

    init(gitStatusProvider: GitStatusProvider = GitStatusProvider()) {
        self.gitStatusProvider = gitStatusProvider
    }

    /// The default producer: runs the digest off the main actor.
    static let defaultProducer: Producer = { repoRoot in
        await Task.detached(priority: .utility) {
            RightSidebarChangesFingerprint().fingerprint(repoRoot: repoRoot)
        }.value
    }

    /// Runs git and stats the listed paths. Synchronous; call off the main actor.
    func fingerprint(repoRoot: String) -> String? {
        guard let status = gitStatusProvider.runGitData(
            in: repoRoot,
            arguments: ["status", "--porcelain=v2", "-z", "--untracked-files=normal"]
        ) else {
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
