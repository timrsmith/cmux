import AppKit
import Bonsplit
import CmuxBrowser
import Foundation
import WebKit

/// Actions the diff viewer page asks the native host to perform itself, on the
/// same `cmuxDiff` bridge and envelope as the sidecar protocol. `DiffSidecarBridge`
/// answers these before anything is forwarded to the Rust sidecar.
///
/// `hostOpenFile {capabilityToken, path}` opens a repository file in the
/// workspace that hosts the viewer. Deny is the default: the request must come
/// from a trusted frame whose token it names and from a web view associated with
/// a live workspace (both checked by `DiffSidecarRequestPolicy`), the path must
/// be repository-relative under the sidecar's rules, and it must resolve, without
/// escaping through symlinks, to an existing regular file inside a repository
/// root that a `.branch-session-<group>.json` allow-list binds to that token.
enum DiffViewerHostActions {
    /// Methods handled natively; the policy treats them like writes.
    static let methods: Set<String> = ["hostOpenFile"]

    private static let maximumSessionFileBytes = 1024 * 1024
    private static let maximumRepoRelativePathBytes = 4096

    enum Failure: Error, Equatable, Sendable {
        /// The token binds no repository containing the path, or the path
        /// escapes every bound repository.
        case notAllowed
        /// The path is not a normalized repository-relative path.
        case invalidPath
        /// The path is inside an allowed repository but no regular file is there.
        case fileNotFound
        /// The web view no longer resolves to a live workspace.
        case unresolvedWorkspace
        /// The workspace declined to open a surface for the file.
        case openFailed

        var code: String {
            switch self {
            case .notAllowed: return "notAllowed"
            case .invalidPath: return "invalidPath"
            case .fileNotFound: return "fileNotFound"
            case .unresolvedWorkspace: return "unresolvedWorkspace"
            case .openFailed: return "openFailed"
            }
        }

        /// Protocol-level detail, mirrored from the sidecar's wording; the page
        /// shows its own localized notice.
        var message: String {
            switch self {
            case .notAllowed: return "Host action is not authorized"
            case .invalidPath: return "Path must be relative to the repository"
            case .fileNotFound: return "The file does not exist in the repository"
            case .unresolvedWorkspace: return "Diff viewer surface not found"
            case .openFailed: return "The workspace could not open the file"
            }
        }
    }

    struct OpenFileRequest: Equatable {
        let capabilityToken: String
        let path: String
    }

    /// One `.branch-session-<group>.json` allow-list, as the CLI writes it and
    /// the sidecar reads it (`BranchSessionAuthorization`).
    private struct BranchSessionAllowList: Decodable {
        let token: String
        let groupID: String
        let allowedRepoRoots: [String]
    }

    /// Parses the `hostOpenFile` params; `nil` for anything malformed.
    static func openFileRequest(from body: [String: Any]) -> OpenFileRequest? {
        guard body["method"] as? String == "hostOpenFile",
              let params = body["params"] as? [String: Any],
              let token = params["capabilityToken"] as? String,
              let path = params["path"] as? String else {
            return nil
        }
        return OpenFileRequest(capabilityToken: token, path: path)
    }

    /// The sidecar's `validate_repo_relative_path`: no leading or trailing
    /// slash, no empty, `.` or `..` components, no NUL bytes, bounded length.
    static func isValidRepoRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path.utf8.count <= maximumRepoRelativePathBytes,
              !path.contains("\0"),
              !path.hasPrefix("/"),
              !path.hasSuffix("/") else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    /// Repository roots every allow-list under `trustedRoot` binds to `token`.
    /// Unreadable, oversized, or malformed files contribute nothing.
    static func allowedRepoRoots(
        forToken token: String,
        trustedRoot: URL = CmuxDiffViewerSessionPreparer.defaultTrustedRootURL
    ) -> [URL] {
        guard CmuxDiffViewerURLSchemeHandler.isValidToken(token),
              let names = try? FileManager.default.contentsOfDirectory(atPath: trustedRoot.path) else {
            return []
        }
        var roots: [URL] = []
        for name in names where name.hasPrefix(".branch-session-") && name.hasSuffix(".json") {
            let group = name.dropFirst(".branch-session-".count).dropLast(".json".count)
            guard (1...64).contains(group.count),
                  group.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
                continue
            }
            let fileURL = trustedRoot.appendingPathComponent(name, isDirectory: false)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? Int, size <= maximumSessionFileBytes,
                  let data = try? Data(contentsOf: fileURL),
                  let session = try? JSONDecoder().decode(BranchSessionAllowList.self, from: data),
                  session.token == token,
                  session.groupID == String(group) else {
                continue
            }
            roots.append(contentsOf: session.allowedRepoRoots.map { URL(fileURLWithPath: $0, isDirectory: true) })
        }
        return roots
    }

    /// Resolves `path` to a regular file inside one of `allowedRepoRoots`. The
    /// file is located after symlink resolution and must still sit under the
    /// resolved root, so a link out of the repository never opens.
    static func resolveFileURL(path: String, allowedRepoRoots: [URL]) throws -> URL {
        guard isValidRepoRelativePath(path) else {
            throw Failure.invalidPath
        }
        var sawMissingFile = false
        for root in allowedRepoRoots {
            let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
            let canonical = canonicalRoot
                .appendingPathComponent(path, isDirectory: false)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let rootPath = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
            guard canonical.path.hasPrefix(rootPath) else {
                continue
            }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: canonical.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else {
                sawMissingFile = true
                continue
            }
            return canonical
        }
        throw sawMissingFile ? Failure.fileNotFound : Failure.notAllowed
    }

    /// Answers a `hostOpenFile` request already admitted by the policy. The
    /// allow-list lookup and path resolution run off the main actor; the open
    /// itself runs on it, through `open` (the workspace's file-open routing).
    @MainActor
    static func handle(
        body: [String: Any],
        webView: WKWebView?,
        open: @MainActor (Workspace, String) -> Bool = openInWorkspace
    ) async -> [String: Any] {
        let id = body["id"] as? String ?? "unknown"
        guard let request = openFileRequest(from: body) else {
            return failure(id: id, .invalidPath)
        }
        guard let workspace = DiffCommentsBridge.associatedWorkspace(for: webView) else {
            return failure(id: id, .unresolvedWorkspace)
        }
        let token = request.capabilityToken
        let path = request.path
        let resolution: Result<URL, Failure> = await Task.detached(priority: .userInitiated) {
            do {
                let roots = allowedRepoRoots(forToken: token)
                return .success(try resolveFileURL(path: path, allowedRepoRoots: roots))
            } catch let failure as Failure {
                return .failure(failure)
            } catch {
                return .failure(.notAllowed)
            }
        }.value
        switch resolution {
        case .failure(let reason):
            return failure(id: id, reason)
        case .success(let fileURL):
            return open(workspace, fileURL.path) ? success(id: id) : failure(id: id, .openFailed)
        }
    }

    /// The same routing the sidebar file tree uses for a click: the focused
    /// pane (or the first), reusing an existing preview of the file.
    @MainActor
    static func openInWorkspace(_ workspace: Workspace, _ path: String) -> Bool {
        guard let pane = workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first else {
            return false
        }
        return !workspace.openFileSurfaces(
            inPane: pane,
            filePaths: [path],
            focus: true,
            reuseExisting: true,
            duplicateWhenFocused: true
        ).isEmpty
    }

    static func success(id: String) -> [String: Any] {
        ["id": id, "version": 1, "result": ["type": "fileOpened"], "error": NSNull()]
    }

    static func failure(id: String, _ failure: Failure) -> [String: Any] {
        [
            "id": id,
            "version": 1,
            "result": NSNull(),
            "error": ["code": failure.code, "message": failure.message],
        ]
    }
}
