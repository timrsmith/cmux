public import Foundation

/// The repository allow-list carried by one diff viewer `.branch-session-<group>.json` file.
///
/// The CLI writes a richer session record next to the viewer manifest (layout,
/// appearance, title and workspace context for regenerating branch pages). Every
/// reader that only authorizes a repository against a capability token decodes
/// this narrower view instead: the token the session was issued for, the group
/// the file is named after, and the repository roots the session may act on.
/// Unknown keys are ignored, so the CLI can extend its record without breaking
/// older readers.
///
/// ```swift
/// let session = try JSONDecoder().decode(DiffViewerBranchSessionAllowList.self, from: data)
/// guard session.token == requestToken else { return [] }
/// ```
public struct DiffViewerBranchSessionAllowList: Decodable, Equatable, Sendable {
    /// The unguessable capability token the page is served under.
    public let token: String
    /// The session group; the file that carries the record is named `.branch-session-<groupID>.json`.
    public let groupID: String
    /// Absolute repository roots the session is allowed to read and regenerate for.
    public let allowedRepoRoots: [String]

    /// Creates an allow-list record.
    ///
    /// - Parameters:
    ///   - token: The capability token the session was issued for.
    ///   - groupID: The session group the file is named after.
    ///   - allowedRepoRoots: Absolute repository roots the session may act on.
    public init(token: String, groupID: String, allowedRepoRoots: [String]) {
        self.token = token
        self.groupID = groupID
        self.allowedRepoRoots = allowedRepoRoots
    }
}
