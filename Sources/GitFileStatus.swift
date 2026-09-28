import Foundation

enum GitFileStatus: Equatable, Sendable {
    case modified, added, deleted, renamed, untracked
}

/// One repository's parsed `git status`, keyed under the explorer's path spelling.
struct GitStatusSnapshot: Equatable, Sendable {
    /// Status per absolute path, including the synthesized parent-directory marks
    /// that walk from each changed file up to (but excluding) the explorer root.
    var statusByPath: [String: GitFileStatus] = [:]
    /// Absolute paths git reports as deleted (`D` in either porcelain column),
    /// grouped by their parent directory and sorted within each group. The file
    /// explorer renders these as ghost rows because the files are gone from disk.
    var deletedPathsByParent: [String: [String]] = [:]

    static let empty = GitStatusSnapshot()
}

/// A discovered repository together with its status snapshot.
struct GitRepositoryStatus: Equatable, Sendable {
    /// The repository working-tree root. Canonical (symlinks resolved) for local
    /// repositories; the remote's own spelling for SSH repositories.
    let repoRoot: String
    let snapshot: GitStatusSnapshot
}
