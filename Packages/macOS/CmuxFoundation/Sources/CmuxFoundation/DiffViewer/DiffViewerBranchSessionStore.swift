public import Foundation

/// Reads the diff viewer's `.branch-session-<group>.json` allow-lists from one directory.
///
/// The CLI's HTTP server and the app's `hostOpenFile` bridge both answer the
/// same question: which repositories does a capability token bind? This store
/// is the single decoder for that answer. It walks `rootDirectory` for
/// `.branch-session-<group>.json` files, skips anything that is not a plausibly
/// named regular file of at most ``maximumSessionFileBytes``, decodes each as a
/// ``DiffViewerBranchSessionAllowList``, and returns the first record whose token
/// matches and whose `groupID` agrees with its file name. Each group is issued
/// for exactly one token, so the first match is the answer. Deny is the default:
/// an invalid token, an unreadable directory, and any malformed file all
/// contribute nothing.
///
/// ```swift
/// let store = DiffViewerBranchSessionStore(rootDirectory: trustedRoot)
/// guard store.allows(repoRoot: requestedRepo, forToken: token) else { return }
/// ```
public struct DiffViewerBranchSessionStore {
    /// Session files larger than this are ignored rather than decoded.
    public static let maximumSessionFileBytes = 1024 * 1024

    private static let fileNamePrefix = ".branch-session-"
    private static let fileNameSuffix = ".json"

    private let rootDirectory: URL
    private let fileManager: FileManager

    /// Creates a store over one session directory.
    ///
    /// - Parameters:
    ///   - rootDirectory: The secure diff viewer directory that holds the manifest and session files.
    ///   - fileManager: The file manager used to list and inspect files; tests pass their own.
    public init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    /// Repository roots the allow-list in the store's directory binds to `token`.
    ///
    /// - Parameter token: The capability token a request presented.
    /// - Returns: The roots of the first valid session file whose token matches,
    ///   as unresolved directory URLs, or an empty array when nothing binds the token.
    public func allowedRepoRoots(forToken token: String) -> [URL] {
        guard let session = session(forToken: token) else { return [] }
        return session.allowedRepoRoots.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Whether `repoRoot` is one of the repositories bound to `token`.
    ///
    /// Both sides are standardized and symlink-resolved before comparison, so a
    /// link to an allow-listed repository neither bypasses nor fails the check.
    ///
    /// - Parameters:
    ///   - repoRoot: The repository root a request names.
    ///   - token: The capability token the request presented.
    /// - Returns: `true` when a session bound to `token` allow-lists `repoRoot`.
    public func allows(repoRoot: String, forToken token: String) -> Bool {
        let roots = allowedRepoRoots(forToken: token)
        guard !roots.isEmpty else { return false }
        let requested = Self.canonicalPath(repoRoot)
        return roots.contains { Self.canonicalPath($0.path) == requested }
    }

    /// The first valid session record in the directory whose token is `token`.
    private func session(forToken token: String) -> DiffViewerBranchSessionAllowList? {
        guard Self.isValidToken(token),
              let names = try? fileManager.contentsOfDirectory(atPath: rootDirectory.path) else {
            return nil
        }
        for name in names.sorted() where name.hasPrefix(Self.fileNamePrefix) && name.hasSuffix(Self.fileNameSuffix) {
            let group = String(name.dropFirst(Self.fileNamePrefix.count).dropLast(Self.fileNameSuffix.count))
            guard Self.isValidGroupID(group) else { continue }
            let fileURL = rootDirectory.appendingPathComponent(name, isDirectory: false)
            guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? Int, size <= Self.maximumSessionFileBytes,
                  let data = fileManager.contents(atPath: fileURL.path),
                  let session = try? JSONDecoder().decode(DiffViewerBranchSessionAllowList.self, from: data),
                  session.token == token,
                  session.groupID == group else {
                continue
            }
            return session
        }
        return nil
    }

    /// Tokens are 16 to 80 ASCII letters, digits, or hyphens, as the URL scheme handler and sidecar require.
    private static func isValidToken(_ token: String) -> Bool {
        let bytes = token.utf8
        guard (16...80).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D:
                true
            default:
                false
            }
        }
    }

    /// Group ids are 1 to 64 letters, digits, or hyphens; anything else is not a session the CLI wrote.
    private static func isValidGroupID(_ group: String) -> Bool {
        (1...64).contains(group.count)
            && group.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
    }
}
