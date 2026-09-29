/// The components of a filesystem path after its last `.git` component, read
/// in place without splitting the whole path.
///
/// Both the forced-root metadata rule and the `git status` relevance filter on
/// ``GitWorkspaceMetadataWatchDescriptor`` judge a path by where it falls
/// under a repository's `.git` directory (or a linked worktree's private
/// directory below `.git/worktrees/`). Construction runs one backward scan over
/// the path's UTF-8 bytes to find the last component that is exactly `.git`, so
/// `.github`, `my.git`, and `.git-old` never match and both `/var` and
/// `/private/var` spellings of one path agree. Iteration yields the non-empty
/// components after that point: repeated and trailing separators are skipped,
/// `/a/.git/` yields nothing, and a relative `.git/index` yields `index`.
struct GitDirectoryRelativePath: Sequence {
    private static let gitDirectoryName = ".git"
    private static let separator = UInt8(ascii: "/")

    private let path: String
    /// Just past the last `.git` component: the separator after it, or the end.
    private let gitDirectoryEnd: String.Index

    /// Finds the last `.git` component of `path`; `nil` when no component is `.git`.
    init?(path: String) {
        guard let gitDirectoryEnd = Self.endOfLastGitComponent(in: path) else { return nil }
        self.path = path
        self.gitDirectoryEnd = gitDirectoryEnd
    }

    func makeIterator() -> Iterator {
        Iterator(path: path, cursor: gitDirectoryEnd)
    }

    /// Walks the components backwards from the end, comparing each against
    /// `.git` in place, so `/a/.git/index` and `/a//.git/` agree and `.github`
    /// is never mistaken for `.git`.
    private static func endOfLastGitComponent(in path: String) -> String.Index? {
        let utf8 = path.utf8
        var end = utf8.endIndex
        while true {
            var start = end
            while start > utf8.startIndex, utf8[utf8.index(before: start)] != separator {
                start = utf8.index(before: start)
            }
            if utf8[start..<end].elementsEqual(gitDirectoryName.utf8) { return end }
            guard start > utf8.startIndex else { return nil }
            end = utf8.index(before: start)
        }
    }

    /// Yields the non-empty components after `.git` in order. A copy taken
    /// mid-walk is an independent lookahead.
    struct Iterator: IteratorProtocol {
        fileprivate let path: String
        fileprivate var cursor: String.Index

        mutating func next() -> Substring? {
            let utf8 = path.utf8
            var start = cursor
            while start < utf8.endIndex, utf8[start] == GitDirectoryRelativePath.separator {
                start = utf8.index(after: start)
            }
            guard start < utf8.endIndex else {
                cursor = start
                return nil
            }
            var end = start
            while end < utf8.endIndex, utf8[end] != GitDirectoryRelativePath.separator {
                end = utf8.index(after: end)
            }
            cursor = end
            return path[start..<end]
        }
    }
}
