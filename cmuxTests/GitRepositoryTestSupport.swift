import Foundation

/// Throwaway local git repositories for tests that exercise real `git status`
/// output (the file explorer's status provider and store).
enum GitRepositoryTestSupport {
    struct GitCommandFailure: Error, CustomStringConvertible {
        let arguments: [String]
        let terminationStatus: Int32

        var description: String {
            "git \(arguments.joined(separator: " ")) failed with status \(terminationStatus)"
        }
    }

    /// A fresh, uniquely named directory under the temporary directory. The
    /// caller removes it.
    static func makeTemporaryDirectory(prefix: String = "cmux-git-test-") throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }

    /// Creates `repoURL` if needed and initializes a repository with a commit
    /// identity, so tests can commit without touching the user's git config.
    static func initializeRepo(at repoURL: URL) throws {
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try runGit(["init", "-q"], in: repoURL)
        try runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
    }

    /// Runs the system git with `arguments` in `directory`, discarding output,
    /// and throws unless it exits 0.
    static func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitCommandFailure(arguments: arguments, terminationStatus: process.terminationStatus)
        }
    }
}
