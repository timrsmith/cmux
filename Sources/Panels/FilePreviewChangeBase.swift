import Foundation

/// The file as git holds it in the index, which the editor's change markers
/// diff against, plus the path git knows it by.
struct FilePreviewChangeBase: Equatable, Sendable {
    let repoRoot: String
    /// Repository-relative path, what a prompt reference names.
    let relativePath: String
    /// Index content; nil when git does not track the file yet or it is not
    /// text, in which case the editor shows no markers.
    let content: String?
}

/// Reads a file's change base through git. Blocking; callers run it off the
/// main actor.
struct FilePreviewChangeBaseReader: Sendable {
    var gitStatus = GitStatusProvider()

    func read(fileURL: URL) -> FilePreviewChangeBase? {
        let directory = fileURL.deletingLastPathComponent().path
        guard let repoRoot = gitStatus.repositoryRoot(for: directory) else { return nil }
        let canonicalFile = GitStatusProvider.canonicalPath(fileURL.path)
        guard canonicalFile.hasPrefix(repoRoot + "/") else { return nil }
        let relativePath = String(canonicalFile.dropFirst(repoRoot.count + 1))
        let data = gitStatus.runGitData(in: repoRoot, arguments: ["show", ":0:\(relativePath)"])
        return FilePreviewChangeBase(
            repoRoot: repoRoot,
            relativePath: relativePath,
            content: data.flatMap { String(data: $0, encoding: .utf8) }
        )
    }
}
