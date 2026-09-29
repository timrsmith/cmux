import Foundation
import Testing

@testable import CmuxFoundation

@Suite struct DiffViewerBranchSessionStoreTests {
    private let token = "0123456789abcdef0123456789abcdef"
    private let otherToken = "fedcba9876543210fedcba9876543210"

    private struct Fixture {
        let root: URL
        let trusted: URL
        let repo: URL
        let other: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-session-store-\(UUID().uuidString)", isDirectory: true)
        let fixture = Fixture(
            root: root,
            trusted: root.appendingPathComponent("trusted", isDirectory: true),
            repo: root.appendingPathComponent("repo", isDirectory: true),
            other: root.appendingPathComponent("other", isDirectory: true)
        )
        for directory in [fixture.trusted, fixture.repo, fixture.other] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return fixture
    }

    private func writeSession(
        _ group: String,
        token: String,
        roots: [URL],
        groupID: String? = nil,
        in trusted: URL
    ) throws {
        // The CLI's record carries more than the allow-list; extra keys are ignored.
        let session: [String: Any] = [
            "token": token,
            "groupID": groupID ?? group,
            "allowedRepoRoots": roots.map(\.path),
            "layout": "unified",
            "repoSourceFiles": [String: [String: String]]()
        ]
        try JSONSerialization.data(withJSONObject: session)
            .write(to: trusted.appendingPathComponent(".branch-session-\(group).json"))
    }

    @Test func matchingTokenReturnsItsRootsAndOthersReturnNothing() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeSession("group-a", token: token, roots: [fixture.repo], in: fixture.trusted)
        try writeSession("group-b", token: otherToken, roots: [fixture.other], in: fixture.trusted)

        let store = DiffViewerBranchSessionStore(rootDirectory: fixture.trusted)
        #expect(store.allowedRepoRoots(forToken: token).map(\.standardizedFileURL.path)
            == [fixture.repo.standardizedFileURL.path])
        #expect(store.allowedRepoRoots(forToken: otherToken).map(\.standardizedFileURL.path)
            == [fixture.other.standardizedFileURL.path])
        #expect(store.allowedRepoRoots(forToken: "00000000000000000000000000000000").isEmpty)
        #expect(store.allowedRepoRoots(forToken: "short").isEmpty)
        #expect(store.allowedRepoRoots(forToken: token + "/../").isEmpty)
        #expect(store.allows(repoRoot: fixture.repo.path, forToken: token))
        #expect(!store.allows(repoRoot: fixture.other.path, forToken: token))
        #expect(!store.allows(repoRoot: fixture.repo.path, forToken: otherToken))
    }

    @Test func malformedOversizedAndBadlyNamedFilesContributeNothing() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let trusted = fixture.trusted
        // Malformed JSON.
        try Data("{".utf8).write(to: trusted.appendingPathComponent(".branch-session-broken.json"))
        // Missing fields.
        try Data("{}".utf8).write(to: trusted.appendingPathComponent(".branch-session-empty.json"))
        // A group name with a space, and one that is too long.
        try writeSession("bad group", token: token, roots: [fixture.repo], in: trusted)
        try writeSession(String(repeating: "g", count: 65), token: token, roots: [fixture.repo], in: trusted)
        // File name and groupID disagree.
        try writeSession("renamed", token: token, roots: [fixture.repo], groupID: "original", in: trusted)
        // Oversized: a valid record padded past the limit.
        var oversized = try JSONSerialization.data(withJSONObject: [
            "token": token, "groupID": "huge", "allowedRepoRoots": [fixture.repo.path]
        ])
        oversized.append(Data(repeating: 0x20, count: DiffViewerBranchSessionStore.maximumSessionFileBytes))
        try oversized.write(to: trusted.appendingPathComponent(".branch-session-huge.json"))
        // A directory with a session name.
        try FileManager.default.createDirectory(
            at: trusted.appendingPathComponent(".branch-session-dir.json"),
            withIntermediateDirectories: true
        )

        let store = DiffViewerBranchSessionStore(rootDirectory: trusted)
        #expect(store.allowedRepoRoots(forToken: token).isEmpty)
        #expect(!store.allows(repoRoot: fixture.repo.path, forToken: token))

        // A valid file alongside them is still found.
        try writeSession("good", token: token, roots: [fixture.repo], in: trusted)
        #expect(store.allows(repoRoot: fixture.repo.path, forToken: token))
    }

    @Test func allowsCanonicalizesSymlinkedRoots() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let link = fixture.root.appendingPathComponent("repo-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.repo)
        try writeSession("linked", token: token, roots: [link], in: fixture.trusted)

        let store = DiffViewerBranchSessionStore(rootDirectory: fixture.trusted)
        // The allow-list names the link; the real directory, a trailing slash,
        // and a `..` hop all resolve to it.
        #expect(store.allows(repoRoot: fixture.repo.path, forToken: token))
        #expect(store.allows(repoRoot: fixture.repo.path + "/", forToken: token))
        #expect(store.allows(repoRoot: fixture.other.path + "/../repo", forToken: token))
        #expect(!store.allows(repoRoot: fixture.other.path, forToken: token))
        // The returned roots keep the allow-list's own spelling.
        #expect(store.allowedRepoRoots(forToken: token).map(\.standardizedFileURL.path)
            == [link.standardizedFileURL.path])
    }

    @Test func missingDirectoryDeniesEverything() {
        let store = DiffViewerBranchSessionStore(
            rootDirectory: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)", isDirectory: true)
        )
        #expect(store.allowedRepoRoots(forToken: token).isEmpty)
        #expect(!store.allows(repoRoot: "/tmp", forToken: token))
        #expect(!store.allows(repoRoot: "/tmp"))
    }

    @Test func tokenlessAllowsAcceptsAnyValidSessionAndAppliesTheSameFileChecks() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let trusted = fixture.trusted
        let store = DiffViewerBranchSessionStore(rootDirectory: trusted)
        #expect(!store.allows(repoRoot: fixture.repo.path))

        // Two sessions for different tokens: either repository is allowed
        // without a token, and a sibling directory never is.
        try writeSession("group-a", token: token, roots: [fixture.repo], in: trusted)
        try writeSession("group-b", token: otherToken, roots: [fixture.other], in: trusted)
        #expect(store.allows(repoRoot: fixture.repo.path))
        #expect(store.allows(repoRoot: fixture.other.path))
        #expect(store.allows(repoRoot: fixture.repo.path + "/"))
        #expect(!store.allows(repoRoot: fixture.root.appendingPathComponent("elsewhere").path))
        #expect(!store.allows(repoRoot: fixture.root.path))

        // Files the token-bound readers reject contribute nothing here either.
        let unlisted = fixture.root.appendingPathComponent("unlisted", isDirectory: true)
        try FileManager.default.createDirectory(at: unlisted, withIntermediateDirectories: true)
        try writeSession("renamed", token: token, roots: [unlisted], groupID: "original", in: trusted)
        try writeSession("bad group", token: token, roots: [unlisted], in: trusted)
        var oversized = try JSONSerialization.data(withJSONObject: [
            "token": token, "groupID": "huge", "allowedRepoRoots": [unlisted.path]
        ])
        oversized.append(Data(repeating: 0x20, count: DiffViewerBranchSessionStore.maximumSessionFileBytes))
        try oversized.write(to: trusted.appendingPathComponent(".branch-session-huge.json"))
        #expect(!store.allows(repoRoot: unlisted.path))
    }

    @Test func containsCanonicalizesBothSides() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let link = fixture.root.appendingPathComponent("repo-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.repo)
        let roots = [link.path, fixture.other.path + "/"]

        #expect(DiffViewerBranchSessionStore.contains(repoRoot: fixture.repo.path, in: roots))
        #expect(DiffViewerBranchSessionStore.contains(repoRoot: link.path, in: roots))
        #expect(DiffViewerBranchSessionStore.contains(repoRoot: fixture.other.path, in: roots))
        #expect(DiffViewerBranchSessionStore.contains(repoRoot: fixture.repo.path + "/../other", in: roots))
        #expect(!DiffViewerBranchSessionStore.contains(repoRoot: fixture.root.path, in: roots))
        #expect(!DiffViewerBranchSessionStore.contains(repoRoot: fixture.repo.path, in: []))
    }
}
