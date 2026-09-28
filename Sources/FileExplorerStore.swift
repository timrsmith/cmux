import CmuxCloud
import CmuxFoundation
import AppKit
import Combine
import Foundation
import QuartzCore
import SwiftUI

// MARK: - Explorer Visual Style

enum FileExplorerStyle: Int, CaseIterable {
    case liquidGlass = 0
    case highDensity = 1
    case terminalStealth = 2
    case proStudio = 3
    case finder = 4

    var label: String {
        switch self {
        case .liquidGlass: return "Liquid Glass"
        case .highDensity: return "High-Density IDE"
        case .terminalStealth: return "Terminal Stealth"
        case .proStudio: return "Pro Studio"
        case .finder: return "Finder"
        }
    }

    var rowHeight: CGFloat {
        let baseHeight: CGFloat
        switch self {
        case .liquidGlass: baseHeight = 28
        case .highDensity: baseHeight = 20
        case .terminalStealth: baseHeight = 24
        case .proStudio: baseHeight = 32
        case .finder: baseHeight = 26
        }
        return GlobalFontMagnification.scaledSize(baseHeight)
    }

    var indentation: CGFloat {
        switch self {
        case .liquidGlass: return 16
        case .highDensity: return 12
        case .terminalStealth: return 14
        case .proStudio: return 20
        case .finder: return 18
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .liquidGlass: return 16
        case .highDensity: return 14
        case .terminalStealth: return 12
        case .proStudio: return 18
        case .finder: return 18
        }
    }

    var iconWeight: NSFont.Weight {
        switch self {
        case .liquidGlass: return .regular
        case .highDensity: return .regular
        case .terminalStealth: return .light
        case .proStudio: return .regular
        case .finder: return .medium
        }
    }

    var nameFont: NSFont {
        switch self {
        case .liquidGlass: return GlobalFontMagnification.systemFont(ofSize: 13, weight: .medium)
        case .highDensity: return GlobalFontMagnification.systemFont(ofSize: 11, weight: .regular)
        case .terminalStealth: return GlobalFontMagnification.monospacedSystemFont(ofSize: 12, weight: .regular)
        case .proStudio: return GlobalFontMagnification.systemFont(ofSize: 14, weight: .semibold)
        case .finder: return GlobalFontMagnification.systemFont(ofSize: 13, weight: .regular)
        }
    }

    var iconToTextSpacing: CGFloat {
        switch self {
        case .liquidGlass: return 8
        case .highDensity: return 4
        case .terminalStealth: return 6
        case .proStudio: return 12
        case .finder: return 6
        }
    }

    var selectionInset: CGFloat {
        switch self {
        case .liquidGlass: return 8
        case .highDensity: return 0
        case .terminalStealth: return 0
        case .proStudio: return 4
        case .finder: return 4
        }
    }

    var selectionRadius: CGFloat {
        switch self {
        case .liquidGlass: return 6
        case .highDensity: return 0
        case .terminalStealth: return 0
        case .proStudio: return 8
        case .finder: return 5
        }
    }

    var selectionColor: NSColor {
        switch self {
        case .liquidGlass: return .controlAccentColor.withAlphaComponent(0.15)
        case .highDensity: return .selectedContentBackgroundColor
        case .terminalStealth: return .controlAccentColor
        case .proStudio: return .controlAccentColor
        case .finder: return .controlAccentColor.withAlphaComponent(0.15)
        }
    }

    var hoverColor: NSColor {
        switch self {
        case .liquidGlass: return .labelColor.withAlphaComponent(0.05)
        case .highDensity: return .white.withAlphaComponent(0.05)
        case .terminalStealth: return .white.withAlphaComponent(0.03)
        case .proStudio: return .white.withAlphaComponent(0.1)
        case .finder: return .labelColor.withAlphaComponent(0.04)
        }
    }

    var usesBorderSelection: Bool {
        self == .terminalStealth
    }

    var fileIconTint: NSColor {
        palette.fileIconTint
    }

    var folderIconTint: NSColor {
        palette.folderIconTint
    }

    func gitColor(for status: GitFileStatus) -> NSColor {
        palette.gitColor(for: status)
    }

    /// Tint for a file type icon category in this style; monochrome styles
    /// return `fileIconTint` for every category.
    func fileTypeTint(_ color: FileTypeIconColor) -> NSColor {
        palette.fileTypeTint(color)
    }

    private var palette: FileExplorerPalette {
        switch self {
        case .liquidGlass: .liquidGlass
        case .highDensity: .highDensity
        case .terminalStealth: .terminalStealth
        case .proStudio: .proStudio
        case .finder: .finder
        }
    }

    static var current: FileExplorerStyle {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "fileExplorer.style") == nil {
            return .highDensity
        }
        return FileExplorerStyle(rawValue: defaults.integer(forKey: "fileExplorer.style")) ?? .highDensity
    }
}

// MARK: - Models

struct FileExplorerEntry: Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
}

final class FileExplorerNode: Identifiable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    /// A path git reports as deleted that no longer exists on disk. Ghost rows
    /// are rendered struck through and cannot be opened, dragged, or revealed.
    /// A ghost directory stands in for a deleted directory whose files are
    /// all ghosts; its `children` are populated by the store, never listed.
    let isGhost: Bool
    /// Invariant: always in `FileExplorerNode.sorted` order. The store assigns
    /// this only from `displayChildren`, which sorts once per listing or ghost
    /// reconciliation, so readers need not re-sort.
    var children: [FileExplorerNode]?
    var isLoading: Bool = false
    var error: String?
    var resourceContextID: UUID?

    init(name: String, path: String, isDirectory: Bool, isGhost: Bool = false) {
        self.id = path
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isGhost = isGhost
    }

    /// Real directories expand by listing; a ghost directory expands only
    /// into the ghost rows the store synthesized for it.
    var isExpandable: Bool {
        guard isDirectory else { return false }
        return isGhost ? (children?.isEmpty == false) : true
    }

    /// `children`, which are kept sorted at every write (see `children`).
    var sortedChildren: [FileExplorerNode]? { children }

    /// Directories first, then case-insensitive by name; the one ordering used
    /// for listings, ghost insertion, and the outline view.
    static func sorted(_ nodes: [FileExplorerNode]) -> [FileExplorerNode] {
        nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

// MARK: - Root Resolver

enum FileExplorerRootResolver {
    static func displayPath(for fullPath: String, homePath: String?) -> String {
        guard let home = homePath, !home.isEmpty else { return fullPath }
        let normalizedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        let normalizedPath = fullPath.hasSuffix("/") ? String(fullPath.dropLast()) : fullPath
        if normalizedPath == normalizedHome {
            return "~"
        }
        let homePrefix = normalizedHome + "/"
        if normalizedPath.hasPrefix(homePrefix) {
            return "~/" + normalizedPath.dropFirst(homePrefix.count)
        }
        return fullPath
    }
}

// MARK: - Provider Protocol

protocol FileExplorerProvider: AnyObject {
    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry]
    var homePath: String { get }
    var isAvailable: Bool { get }
}

struct SSHFileExplorerConnection: Equatable, Sendable {
    let destination: String
    let port: Int?
    let identityFile: String?
    let sshOptions: [String]
}

protocol SSHFileExplorerTransport: AnyObject {
    nonisolated func resolveHomePath(connection: SSHFileExplorerConnection) async throws -> String
    nonisolated func listDirectory(
        path: String,
        connection: SSHFileExplorerConnection,
        showHidden: Bool
    ) async throws -> [FileExplorerEntry]
    nonisolated func downloadFile(
        path: String,
        connection: SSHFileExplorerConnection,
        to localURL: URL
    ) async throws
}

enum FileExplorerWorkspaceRoot: Equatable {
    case none
    case local(workspaceId: UUID, path: String)
    case remoteSSH(
        workspaceId: UUID,
        connection: SSHFileExplorerConnection,
        displayTarget: String,
        rootPath: String?,
        isAvailable: Bool,
        unavailableDetail: String?
    )
    case remoteCloud(
        workspaceId: UUID,
        vmID: String,
        displayTarget: String,
        rootPath: String?,
        isAvailable: Bool,
        unavailableDetail: String?,
        target: CloudFileExplorerTarget?
    )
}

// MARK: - Local Provider

final class LocalFileExplorerProvider: FileExplorerProvider {
    var homePath: String { NSHomeDirectory() }
    var isAvailable: Bool { true }

    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(atPath: path)
        return contents.compactMap { name in
            guard showHidden || !name.hasPrefix(".") else { return nil }
            let fullPath = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { return nil }
            return FileExplorerEntry(name: name, path: fullPath, isDirectory: isDir.boolValue)
        }
    }
}

// MARK: - SSH Provider

// Captured by async SSH tasks; mutable availability/root state is guarded by stateLock.
final class SSHFileExplorerProvider: RemoteFileExplorerProvider, @unchecked Sendable {
    private struct State: Sendable {
        var homePath: String
        var isAvailable: Bool
    }

    let connection: SSHFileExplorerConnection
    let displayTarget: String
    private let transport: SSHFileExplorerTransport
    private let stateLock = NSLock()
    private var state: State

    var homePath: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state.homePath
    }

    var isAvailable: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state.isAvailable
    }

    var destination: String { connection.destination }
    nonisolated var remoteIdentity: String {
        "ssh:\(connection.destination)|\(connection.port.map(String.init) ?? "")|\(connection.identityFile ?? "")|\(connection.sshOptions.joined(separator: "\u{1f}"))"
    }
    var port: Int? { connection.port }
    var identityFile: String? { connection.identityFile }
    var sshOptions: [String] { connection.sshOptions }

    init(
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions: [String],
        displayTarget: String? = nil,
        homePath: String,
        isAvailable: Bool,
        transport: SSHFileExplorerTransport = ProcessSSHFileExplorerTransport.shared
    ) {
        self.connection = SSHFileExplorerConnection(
            destination: destination,
            port: port,
            identityFile: identityFile,
            sshOptions: sshOptions
        )
        self.displayTarget = displayTarget ?? {
            guard let port else { return destination }
            return "\(destination):\(port)"
        }()
        self.transport = transport
        self.state = State(homePath: homePath, isAvailable: isAvailable)
    }

    init(
        connection: SSHFileExplorerConnection,
        displayTarget: String,
        homePath: String,
        isAvailable: Bool,
        transport: SSHFileExplorerTransport = ProcessSSHFileExplorerTransport.shared
    ) {
        self.connection = connection
        self.displayTarget = displayTarget
        self.transport = transport
        self.state = State(homePath: homePath, isAvailable: isAvailable)
    }

    func updateAvailability(_ available: Bool, homePath: String?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        state.isAvailable = available
        if let homePath {
            state.homePath = homePath
        }
    }

    func resolveHomePath() async throws -> String {
        guard isAvailable else {
            throw FileExplorerError.providerUnavailable
        }
        let home = try await transport.resolveHomePath(connection: connection)
        guard !home.isEmpty else {
            throw FileExplorerError.sshCommandFailed("remote HOME was empty")
        }
        return home
    }

    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        guard isAvailable else {
            throw FileExplorerError.providerUnavailable
        }
        return try await transport.listDirectory(path: path, connection: connection, showHidden: showHidden)
    }

    func downloadFile(path: String, to localURL: URL) async throws {
        guard isAvailable else {
            throw FileExplorerError.providerUnavailable
        }
        try await transport.downloadFile(path: path, connection: connection, to: localURL)
    }
}

final class ProcessSSHFileExplorerTransport: SSHFileExplorerTransport {
    static let shared = ProcessSSHFileExplorerTransport()

    nonisolated func resolveHomePath(connection: SSHFileExplorerConnection) async throws -> String {
        let output = try await Self.runSSHCommand(
            connection: connection,
            command: #"printf '%s\n' "$HOME""#
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated func listDirectory(
        path: String,
        connection: SSHFileExplorerConnection,
        showHidden: Bool
    ) async throws -> [FileExplorerEntry] {
        try await Self.runSSHListCommand(path: path, connection: connection, showHidden: showHidden)
    }

    nonisolated func downloadFile(
        path: String,
        connection: SSHFileExplorerConnection,
        to localURL: URL
    ) async throws {
        let escapedPath = Self.remoteShellPathWord(path)
        let outputURL = localURL
        let commandProcess = SSHDownloadCommandProcess(
            connection: connection,
            command: "test -f \(escapedPath) && cat -- \(escapedPath)",
            outputURL: outputURL
        )
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try commandProcess.run() })
                }
            }
        } onCancel: {
            commandProcess.terminate()
        }
        guard result.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw FileExplorerError.sshCommandFailed(result.stderr)
        }
    }

    private struct SSHCommandResult: Sendable {
        let stdout: String
        let stderr: String
        let terminationStatus: Int32
    }

    // Keeps the child process reachable from the cancellation handler while
    // the blocking wait runs off Swift's cooperative executor.
    private final class SSHCommandProcess: @unchecked Sendable {
        private let process = Process()
        private let outPipe = Pipe()
        private let errPipe = Pipe()
        private let lock = NSLock()
        private var terminationGate = ProcessTerminationGate()
        private var cancelled = false

        init(connection: SSHFileExplorerConnection, command: String) {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ProcessSSHFileExplorerTransport.sshArguments(connection: connection, command: command)
            process.standardOutput = outPipe
            process.standardError = errPipe
        }

        func run() throws -> SSHCommandResult {
            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled {
                throw CancellationError()
            }

            do {
                try process.run()
            } catch {
                lock.lock()
                terminationGate.markFinished()
                lock.unlock()
                throw error
            }

            lock.lock()
            let shouldTerminate = cancelled
            let shouldTerminateDeferredRequest = terminationGate.markLaunched()
            lock.unlock()
            if shouldTerminateDeferredRequest || shouldTerminate {
                guard process.isRunning else {
                    process.waitUntilExit()
                    lock.lock()
                    terminationGate.markFinished()
                    lock.unlock()
                    throw CancellationError()
                }
                process.terminate()
            }

            let data = outPipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
            let stderrData = errPipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
            process.waitUntilExit()
            lock.lock()
            terminationGate.markFinished()
            let cancelledAfterExit = cancelled
            lock.unlock()
            if cancelledAfterExit {
                throw CancellationError()
            }

            return SSHCommandResult(
                stdout: String(data: data, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? "",
                terminationStatus: process.terminationStatus
            )
        }

        func terminate() {
            lock.lock()
            cancelled = true
            let shouldTerminate = terminationGate.requestTermination()
            lock.unlock()

            guard shouldTerminate else {
                return
            }
            guard process.isRunning else {
                return
            }
            process.terminate()
        }
    }

    private final class SSHDownloadCommandProcess: @unchecked Sendable {
        private let process = Process()
        private let outPipe = Pipe()
        private let errPipe = Pipe()
        private let outputURL: URL
        private let lock = NSLock()
        private var terminationGate = ProcessTerminationGate()
        private var cancelled = false

        init(connection: SSHFileExplorerConnection, command: String, outputURL: URL) {
            self.outputURL = outputURL
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ProcessSSHFileExplorerTransport.sshArguments(connection: connection, command: command)
            process.standardOutput = outPipe
            process.standardError = errPipe
        }

        func run() throws -> SSHCommandResult {
            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled {
                throw CancellationError()
            }

            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            let outputHandle = try FileHandle(forWritingTo: outputURL)
            defer { try? outputHandle.close() }

            do {
                try process.run()
            } catch {
                lock.lock()
                terminationGate.markFinished()
                lock.unlock()
                throw error
            }

            lock.lock()
            let shouldTerminate = cancelled
            let shouldTerminateDeferredRequest = terminationGate.markLaunched()
            lock.unlock()
            if shouldTerminateDeferredRequest || shouldTerminate {
                guard process.isRunning else {
                    process.waitUntilExit()
                    lock.lock()
                    terminationGate.markFinished()
                    lock.unlock()
                    throw CancellationError()
                }
                process.terminate()
            }

            try outPipe.fileHandleForReading.copyDataToEndOfFile(to: outputHandle)
            let stderrData = errPipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
            process.waitUntilExit()
            lock.lock()
            terminationGate.markFinished()
            let cancelledAfterExit = cancelled
            lock.unlock()
            if cancelledAfterExit {
                throw CancellationError()
            }

            return SSHCommandResult(
                stdout: "",
                stderr: String(data: stderrData, encoding: .utf8) ?? "",
                terminationStatus: process.terminationStatus
            )
        }

        func terminate() {
            lock.lock()
            cancelled = true
            let shouldTerminate = terminationGate.requestTermination()
            lock.unlock()

            guard shouldTerminate else {
                return
            }
            guard process.isRunning else {
                return
            }
            process.terminate()
        }
    }

    private static func runSSHCommand(connection: SSHFileExplorerConnection, command: String) async throws -> String {
        let commandProcess = SSHCommandProcess(connection: connection, command: command)
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try commandProcess.run() })
                }
            }
        } onCancel: {
            commandProcess.terminate()
        }

        guard result.terminationStatus == 0 else {
            throw FileExplorerError.sshCommandFailed(result.stderr)
        }
        return result.stdout
    }

    private static func sshArguments(connection: SSHFileExplorerConnection, command: String) -> [String] {
        var args: [String] = SSHHostConfiguredRemoteCommand().overrideArguments
        if let port = connection.port {
            args += ["-p", String(port)]
        }
        if let identityFile = connection.identityFile {
            args += ["-i", identityFile]
        }
        for option in connection.sshOptions {
            args += ["-o", option]
        }
        // Batch mode, no TTY, connection timeout
        args += ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-T"]
        // Forwarding stays as configured: without `ControlMaster=no` this run
        // can become the shared master that interactive sessions reuse.
        args += ["--", connection.destination, command]
        return args
    }

    private static func runSSHListCommand(
        path: String,
        connection: SSHFileExplorerConnection,
        showHidden: Bool
    ) async throws -> [FileExplorerEntry] {
        let escapedPath = remoteShellPathWord(path)
        let lsFlags = showHidden ? "-1paFA" : "-1paF"
        let output = try await runSSHCommand(
            connection: connection,
            command: "ls \(lsFlags) \(escapedPath) 2>/dev/null"
        )

        let normalizedPath = path.hasSuffix("/") ? path : path + "/"
        return output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let entry = String(line)
            // Skip . and .. entries
            guard entry != "./" && entry != "../" else { return nil }
            let isDir = entry.hasSuffix("/")
            let name = isDir ? String(entry.dropLast()) : entry
            guard showHidden || !name.hasPrefix(".") else { return nil }
            // Strip type indicators from -F flag (*, @, =, |) for files
            let cleanName: String
            if !isDir, let last = name.last, "*@=|".contains(last) {
                cleanName = String(name.dropLast())
            } else {
                cleanName = name
            }
            let fullPath = normalizedPath + cleanName
            return FileExplorerEntry(name: cleanName, path: fullPath, isDirectory: isDir)
        }
    }

    /// Shell word that expands to `path` on the remote host, byte for byte.
    ///
    /// `Process` passes arguments through `fileSystemRepresentation`, which
    /// decomposes them to NFD. Remote Linux filesystems usually store names in
    /// NFC and treat the two forms as different files, so a non-ASCII path must
    /// not appear literally in the ssh command. Such paths travel base64-encoded
    /// and are decoded by the remote shell.
    static func remoteShellPathWord(_ path: String) -> String {
        guard !path.unicodeScalars.allSatisfy(\.isASCII) else {
            return shellSingleQuote(path)
        }
        let encoded = shellSingleQuote(Data(path.utf8).base64EncodedString())
        // GNU coreutils and macOS accept --decode, BusyBox (Alpine) only -d;
        // -D is the older macOS short flag.
        let decode = ["--decode", "-d", "-D"]
            .map { "printf '%s' \(encoded) | base64 \($0) 2>/dev/null" }
            .joined(separator: " || ")
        return "\"$(\(decode))\""
    }

    private static func shellSingleQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

enum FileExplorerError: LocalizedError {
    case providerUnavailable
    case sshCommandFailed(String)
    case remoteCommandFailed(String)
    case previewCapacity
    case remoteFileTooLarge

    var errorDescription: String? {
        switch self {
        case .providerUnavailable:
            return String(localized: "fileExplorer.error.unavailable", defaultValue: "File explorer is not available")
        case .sshCommandFailed:
            return String(localized: "fileExplorer.error.sshFailed", defaultValue: "SSH command failed")
        case .previewCapacity:
            return String(localized: "fileExplorer.preview.capacity", defaultValue: "Close a Cloud file preview and try again.")
        case .remoteFileTooLarge:
            return String(localized: "fileExplorer.error.cloudPreviewTooLarge", defaultValue: "Cloud file previews are limited to 1 MB.")
        case .remoteCommandFailed:
            return String(localized: "fileExplorer.error.remoteFailed", defaultValue: "Remote command failed")
        }
    }
}

// MARK: - Selection Restoration

enum FileExplorerSelectionRestoration {
    static func scrollRow(anchorRow: Int?, exactRows: IndexSet) -> Int? {
        if let anchorRow, exactRows.contains(anchorRow) {
            return anchorRow
        }
        return exactRows.first
    }
}

// MARK: - Store

/// Main-actor store for file-explorer presentation and loading state.
@MainActor
final class FileExplorerStore: ObservableObject {
    @Published var rootPath: String = ""
    @Published var rootNodes: [FileExplorerNode] = []
    @Published private(set) var isRootLoading: Bool = false
    /// Merged status across every discovered repository (see `statusByRepoRoot`).
    @Published private(set) var gitStatusByPath: [String: GitFileStatus] = [:]
    /// The single trigger for reconfiguring the visible rows after a status
    /// change. It is bumped exactly when `gitStatusByPath` is replaced, so the
    /// outline view compares one integer per store update instead of diffing
    /// the dictionary, and a status-only change (no listing changed, so
    /// `contentRevision` is untouched) still recolors root-level file rows
    /// that no structural reload would visit.
    @Published private(set) var gitStatusRevision = 0
    @Published private(set) var contentRevision = 0
    @Published private(set) var rootStatusMessage: String?
    private(set) var workspaceRootIdentity: UUID?

    /// Deleted (ghost) file paths per parent directory, merged across repositories.
    private(set) var deletedPathsByParent: [String: [String]] = [:]
    /// Directories that may be missing from disk because git only knows them
    /// through deleted files, keyed by parent (see `rebuildGhostDirectoryIndex`).
    private var ghostDirectoriesByParent: [String: Set<String>] = [:]

    var provider: FileExplorerProvider?

    /// Whether hidden files are shown. Set from FileExplorerState externally.
    var showHiddenFiles: Bool = false

    /// Watches the root directory for filesystem changes (local only).
    private var directoryWatcher: FileWatcher?
    private var directoryWatchTask: Task<Void, Never>?
    private var directoryWatchPath: String?

    /// Paths that are logically expanded (persisted across provider changes)
    private(set) var expandedPaths: Set<String> = []

    /// Stable navigation selection. The outline view mirrors this path after reloads.
    private(set) var selectedPath: String?

    /// Stable multi-selection. `selectedPath` remains the keyboard/navigation anchor.
    private(set) var selectedPaths: Set<String> = []

    /// Folder path whose first child should be selected once its async load completes.
    private var pendingDescendIntoFirstChildPath: String?

    /// Paths currently being loaded
    private(set) var loadingPaths: Set<String> = []

    /// In-flight load tasks keyed by path
    private var loadTasks: [String: Task<Void, Never>] = [:]

    /// Cache of path -> node for quick lookup
    private var nodesByPath: [String: FileExplorerNode] = [:]

    /// Prefetch debounce schedulers keyed by path.
    private var prefetchSchedulers: [String: MainActorDeferredActionScheduler] = [:]

    var workspaceRootObservation: FileExplorerWorkspaceObservation?
    var remoteHomeResolutionTask: Task<Void, Never>?
    var remoteHomeResolutionKey: String?
    let cloudPreviewCache = CloudFilePreviewCache()
    private(set) var resourceContextID = UUID()

    private let gitStatusProvider: GitStatusProvider
    private let repositoryWatchFactory: GitStatusRepositoryWatchFactory
    /// Monotonic token source for every asynchronous git request.
    private var gitStatusGeneration: UInt64 = 0

    // MARK: Per-repository git index
    //
    // Repositories are discovered per directory (the root always, a nested
    // directory when its listing shows a `.git` entry) and fetched once each.
    // `gitStatusByPath` is the merge of every snapshot; nested repositories
    // override the parent-directory marks of the repositories enclosing them.

    /// Repository root per probed directory; `.some(nil)` caches "not a repository".
    private var repoRootByDirectory: [String: String?] = [:]
    /// Latest snapshot per repository root.
    private var statusByRepoRoot: [String: GitStatusSnapshot] = [:]
    /// Token of the run that produced `statusByRepoRoot[repoRoot]`. Runs land
    /// out of order (a discover for a symlinked directory and a watcher-driven
    /// refetch can target the same repository concurrently), and a run that
    /// started later observed a later state of the work tree, so a snapshot
    /// is only accepted when its token is newer than the stored one.
    private var snapshotGenerationByRepoRoot: [String: UInt64] = [:]
    /// Latest accepted request token per probed directory.
    private var discoveryGenerationByDirectory: [String: UInt64] = [:]
    /// Token of the `git status` run in flight per repository; absent when none
    /// is running, which is what makes `refetchRepository` single-flight.
    private var fetchGenerationByRepoRoot: [String: UInt64] = [:]
    /// Repositories that changed again while their run was in flight; each is
    /// refetched once more when that run lands.
    private var dirtyRepoRoots: Set<String> = []
    /// `rootPath` in the physical spelling git prints (resolved once per root
    /// instead of resolving symlinks on every fetch).
    private var canonicalRootPathCache: (rootPath: String, canonical: String)?
    /// Live watchers per local repository root, their event consumers, and
    /// the in-flight registrations.
    private var repositoryWatches: [String: GitStatusRepositoryWatch] = [:]
    private var repositoryWatchTasks: [String: Task<Void, Never>] = [:]
    private var repositoryWatchStartTasks: [String: Task<Void, Never>] = [:]
    /// Whether the root listing has completed for the current tree, so ghost
    /// reconciliation may touch `rootNodes`.
    private var rootListingLoaded = false

    init(
        gitStatusProvider: GitStatusProvider = GitStatusProvider(),
        repositoryWatchFactory: @escaping GitStatusRepositoryWatchFactory = GitStatusRepositoryWatching.defaultFactory
    ) {
        self.gitStatusProvider = gitStatusProvider
        self.repositoryWatchFactory = repositoryWatchFactory
    }

    var displayRootPath: String {
        if rootPath.isEmpty, let cloudProvider = provider as? CloudVMFileExplorerProvider {
            return cloudProvider.displayTarget
        }
        if let sshProvider = provider as? SSHFileExplorerProvider {
            guard !rootPath.isEmpty else {
                return "ssh://\(sshProvider.displayTarget)"
            }
            return "ssh://\(sshProvider.displayTarget):\(rootPath)"
        }
        return FileExplorerRootResolver.displayPath(for: rootPath, homePath: provider?.homePath)
    }

    // MARK: - Public API

    func applyWorkspaceRoot(
        _ request: FileExplorerWorkspaceRoot,
        sshTransport: SSHFileExplorerTransport = ProcessSSHFileExplorerTransport.shared
    ) {
        switch request {
        case .none:
            workspaceRootObservation?.stop(); workspaceRootObservation = nil
            cancelRemoteHomeResolution(); setRootStatusMessage(nil); setWorkspaceRootIdentity(nil)
            if provider != nil { setProvider(nil, reloadIfAvailable: false) }
            setRootPath("")
        case .local(let workspaceId, let path):
            cancelRemoteHomeResolution(); setRootStatusMessage(nil); setWorkspaceRootIdentity(workspaceId)
            if !(provider is LocalFileExplorerProvider) {
                setRootPath("")
                setProvider(LocalFileExplorerProvider(), reloadIfAvailable: false)
            }
            setRootPath(path)
        case .remoteSSH(let workspaceId, let connection, let displayTarget, let rootPath, let isAvailable, let unavailableDetail):
            applyRemoteSSHWorkspaceRoot(
                workspaceId: workspaceId,
                connection: connection,
                displayTarget: displayTarget,
                rootPath: rootPath,
                isAvailable: isAvailable,
                unavailableDetail: unavailableDetail,
                sshTransport: sshTransport
            )
        case .remoteCloud(let workspaceId, let vmID, let displayTarget, let rootPath, let isAvailable, let unavailableDetail, let target):
            applyRemoteCloudWorkspaceRoot(
                workspaceId: workspaceId,
                vmID: vmID,
                displayTarget: displayTarget,
                rootPath: rootPath,
                isAvailable: isAvailable,
                unavailableDetail: unavailableDetail, target: target
            )
        }
    }
    func setWorkspaceRootIdentity(_ identity: UUID?) {
        guard workspaceRootIdentity != identity else { return }
        workspaceRootIdentity = identity
        resetResourceContext()
        rootPath = ""
        updateDirectoryWatcher()
    }

    func setRootStatusMessage(_ message: String?) {
        guard rootStatusMessage != message else { return }
        rootStatusMessage = message
    }

    private func resetResourceContext(preservingNavigation: Bool = false) {
        resourceContextID = UUID()
        cancelRemoteHomeResolution()
        cancelAllLoads()
        if !preservingNavigation {
            selectedPath = nil; selectedPaths = []; expandedPaths = []
        }
        rootNodes = []; nodesByPath = [:]; rootListingLoaded = false
        resetGitStatusIndex()
        contentRevision &+= 1
    }

    func setRootPath(_ path: String) {
        guard path != rootPath else {
            #if DEBUG
            NSLog("[FileExplorer] setRootPath skipped (same path): \(path)")
            #endif
            return
        }
        #if DEBUG
        NSLog("[FileExplorer] setRootPath: \(rootPath) -> \(path)")
        #endif
        if let selectedPath, !Self.path(selectedPath, isContainedIn: path) {
            self.selectedPath = nil
            selectedPaths = []
            pendingDescendIntoFirstChildPath = nil
        }
        resourceContextID = UUID()
        rootPath = path
        resetGitStatusIndex()
        reload()
        refreshGitStatus()
        updateDirectoryWatcher()
    }

    /// Re-resolves the root repository and re-fetches every repository already
    /// discovered below the root. Nested repositories not yet discovered are
    /// picked up by their directory listings (`loadChildren`).
    func refreshGitStatus() {
        refreshGitStatus(includingNestedRepositories: true)
    }

    /// Root-listing changes only re-resolve and re-fetch the root repository;
    /// nested local repositories have their own watchers. The root repository
    /// is refetched even when it has a watcher of its own: that watcher's
    /// descriptor filter passes only tracked paths, so an untracked file
    /// created or deleted at the root is seen by the directory watcher alone.
    /// When both fire for one save, `refetchRepository` coalesces the pair
    /// into at most two runs (single-flight plus one dirty follow-up).
    private func refreshRootRepositoryStatus() {
        refreshGitStatus(includingNestedRepositories: false)
    }

    private func refreshGitStatus(includingNestedRepositories: Bool) {
        guard gitStatusIsSupported else {
            resetGitStatusIndex()
            return
        }
        let root = rootPath
        var repoRootsToRefetch: Set<String> = includingNestedRepositories ? Set(statusByRepoRoot.keys) : []
        if case .some(.some(let rootRepo)) = repoRootByDirectory[root] {
            // The root already resolved to a repository: a plain refetch is enough.
            repoRootsToRefetch.insert(rootRepo)
        } else {
            discoverRepository(at: root, requiresGitEntry: false)
        }
        for repoRoot in repoRootsToRefetch {
            refetchRepository(repoRoot)
        }
    }

    // MARK: - Per-repository git status

    private var gitStatusIsSupported: Bool {
        guard !rootPath.isEmpty, let provider, provider.isAvailable else { return false }
        return provider is LocalFileExplorerProvider || provider is SSHFileExplorerProvider
    }

    private var sshConnection: SSHFileExplorerConnection? {
        (provider as? SSHFileExplorerProvider)?.connection
    }

    private func nextGitStatusGeneration() -> UInt64 {
        gitStatusGeneration &+= 1
        return gitStatusGeneration
    }

    /// Drops every repository, snapshot, pending request, and watcher. Called
    /// when the root changes or the resource context is reset.
    private func resetGitStatusIndex() {
        gitStatusGeneration &+= 1
        repoRootByDirectory = [:]
        statusByRepoRoot = [:]
        snapshotGenerationByRepoRoot = [:]
        discoveryGenerationByDirectory = [:]
        fetchGenerationByRepoRoot = [:]
        dirtyRepoRoots = []
        stopAllRepositoryWatches()
        deletedPathsByParent = [:]
        ghostDirectoriesByParent = [:]
        if !gitStatusByPath.isEmpty {
            gitStatusByPath = [:]
            gitStatusRevision &+= 1
        }
    }

    /// Forgets cached "not a repository" answers so the next listing re-probes;
    /// positive answers stay because their repositories are refetched explicitly.
    private func forgetNegativeRepositoryProbes() {
        repoRootByDirectory = repoRootByDirectory.filter { $0.value != nil }
    }

    /// Cheap pre-filter for nested repository discovery, run after a directory
    /// listing arrives. Probes only where a `.git` entry is plausible:
    /// - local: the listing shows `.git`, or hidden files are off and a stat off
    ///   the main actor decides;
    /// - SSH: only when the listing shows `.git` (a remote stat costs a round trip).
    private func discoverNestedRepositoryIfNeeded(directory: String, listingNames: [String]) {
        guard gitStatusIsSupported, directory != rootPath else { return }
        if let cached = repoRootByDirectory[directory] {
            // A known repository stays known; a cached negative is only revisited
            // when the listing now shows `.git`.
            guard cached == nil, listingNames.contains(".git") else { return }
        }
        let listingShowsGit = listingNames.contains(".git")
        if provider is LocalFileExplorerProvider {
            if showHiddenFiles, !listingShowsGit {
                repoRootByDirectory[directory] = .some(nil)
                return
            }
            discoverRepository(at: directory, requiresGitEntry: !listingShowsGit)
        } else if sshConnection != nil {
            guard listingShowsGit else { return }
            discoverRepository(at: directory, requiresGitEntry: false)
        }
    }

    /// The `git status` fetch for one repository, bound to the provider, root,
    /// and connection at the time it was made so it can run detached from the
    /// main actor. SSH resolves and fetches in one round trip and never
    /// canonicalizes (remote paths must not be resolved locally); local fetches
    /// compare against the canonical explorer root and key under the store's.
    private struct RepositoryStatusFetch: Sendable {
        let provider: GitStatusProvider
        /// The store's `rootPath`; every emitted key is spelled under it.
        let keyRoot: String
        /// `keyRoot` in the physical spelling git prints, for containment checks.
        let canonicalRoot: String
        let connection: SSHFileExplorerConnection?

        /// Resolves the repository containing `directory` and fetches its status,
        /// or `nil` when there is none. `requiresGitEntry` makes a local probe
        /// bail unless `directory/.git` exists, which keeps unrelated directories
        /// to one stat.
        func discover(directory: String, requiresGitEntry: Bool) -> GitRepositoryStatus? {
            if connection != nil { return fetchSSH(directory: directory) }
            if requiresGitEntry,
               !FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent(".git")) {
                return nil
            }
            guard let repoRoot = provider.repositoryRoot(for: directory) else { return nil }
            // A nested directory whose repository resolves outside the explorer
            // root (a symlink into another checkout, a `.git` file pointing
            // elsewhere) contributes no rows below the root, so it is treated
            // as "not a repository": nothing to fetch or watch. The explorer
            // root itself may of course sit inside an enclosing repository.
            if directory != keyRoot, !GitStatusProvider.path(repoRoot, isContainedIn: canonicalRoot) {
                return nil
            }
            return GitRepositoryStatus(repoRoot: repoRoot, snapshot: fetchLocal(repoRoot: repoRoot))
        }

        /// Re-runs `git status` for one known repository root.
        func refetch(repoRoot: String) -> GitStatusSnapshot {
            if connection != nil { return fetchSSH(directory: repoRoot)?.snapshot ?? .empty }
            return fetchLocal(repoRoot: repoRoot)
        }

        private func fetchSSH(directory: String) -> GitRepositoryStatus? {
            guard let connection else { return nil }
            return provider.fetchRepositoryStatusSSH(
                directory: directory, explorerRoot: keyRoot, destination: connection.destination,
                port: connection.port, identityFile: connection.identityFile, sshOptions: connection.sshOptions
            )
        }

        private func fetchLocal(repoRoot: String) -> GitStatusSnapshot {
            provider.fetchSnapshot(repoRoot: repoRoot, explorerRoot: canonicalRoot, keyRoot: keyRoot)
        }
    }

    /// A fetch bound to the current root and provider. The canonical root is
    /// resolved on the first local fetch for a root and reused afterwards.
    private func makeRepositoryStatusFetch() -> RepositoryStatusFetch {
        let root = rootPath
        let connection = sshConnection
        let canonicalRoot: String
        if connection != nil {
            canonicalRoot = root
        } else if let cached = canonicalRootPathCache, cached.rootPath == root {
            canonicalRoot = cached.canonical
        } else {
            canonicalRoot = GitStatusProvider.canonicalPath(root)
            canonicalRootPathCache = (rootPath: root, canonical: canonicalRoot)
        }
        return RepositoryStatusFetch(
            provider: gitStatusProvider, keyRoot: root, canonicalRoot: canonicalRoot, connection: connection
        )
    }

    /// Resolves the repository containing `directory` and fetches its status off
    /// the main actor (see `RepositoryStatusFetch.discover`).
    private func discoverRepository(at directory: String, requiresGitEntry: Bool) {
        guard gitStatusIsSupported else { return }
        let generation = nextGitStatusGeneration()
        discoveryGenerationByDirectory[directory] = generation
        let context = resourceContextID, fetch = makeRepositoryStatusFetch()
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                fetch.discover(directory: directory, requiresGitEntry: requiresGitEntry)
            }.value
            guard let self, self.resourceContextID == context,
                  self.discoveryGenerationByDirectory[directory] == generation else { return }
            self.discoveryGenerationByDirectory.removeValue(forKey: directory)
            guard let result else {
                self.repoRootByDirectory[directory] = .some(nil)
                return
            }
            self.repoRootByDirectory[directory] = result.repoRoot
            // Ordering with a concurrent refetch of the same repository: both
            // go through `storeSnapshot`, which keeps whichever run started
            // later. A refetch that started earlier and lands afterwards is
            // dropped there instead of overwriting this fresher snapshot.
            self.storeSnapshot(result.snapshot, for: result.repoRoot, generation: generation)
            self.startRepositoryWatchIfNeeded(repoRoot: result.repoRoot)
        }
    }

    /// Records `snapshot` as the current status of `repoRoot` unless a run
    /// that started later has already landed, and rebuilds the merged index
    /// when it was accepted.
    private func storeSnapshot(_ snapshot: GitStatusSnapshot, for repoRoot: String, generation: UInt64) {
        if let stored = snapshotGenerationByRepoRoot[repoRoot], stored > generation { return }
        snapshotGenerationByRepoRoot[repoRoot] = generation
        statusByRepoRoot[repoRoot] = snapshot
        rebuildMergedGitStatus()
    }

    /// Re-runs `git status` for one known repository. Single-flight per
    /// repository: an event that lands while a run is in progress marks the
    /// repository dirty and schedules exactly one follow-up run when that run
    /// completes, so a burst of watcher events costs at most two processes
    /// instead of one each and the final snapshot still reflects the last event.
    private func refetchRepository(_ repoRoot: String) {
        guard gitStatusIsSupported else { return }
        if fetchGenerationByRepoRoot[repoRoot] != nil {
            dirtyRepoRoots.insert(repoRoot)
            return
        }
        let generation = nextGitStatusGeneration()
        fetchGenerationByRepoRoot[repoRoot] = generation
        let context = resourceContextID, fetch = makeRepositoryStatusFetch()
        Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                fetch.refetch(repoRoot: repoRoot)
            }.value
            guard let self, self.resourceContextID == context,
                  self.fetchGenerationByRepoRoot[repoRoot] == generation else { return }
            // Release the in-flight token first: a timed-out or failed run
            // reports an empty snapshot and must still let the next event
            // schedule a fresh run.
            self.fetchGenerationByRepoRoot.removeValue(forKey: repoRoot)
            self.storeSnapshot(snapshot, for: repoRoot, generation: generation)
            if self.dirtyRepoRoots.remove(repoRoot) != nil {
                self.refetchRepository(repoRoot)
            }
        }
    }

    #if DEBUG
    /// The cached repository probe for `directory`: `nil` when never probed,
    /// `.some(nil)` for "not a repository", otherwise the repository root.
    func cachedRepositoryRootForTesting(directory: String) -> String?? {
        repoRootByDirectory[directory]
    }

    /// Whether a `git status` run for `repoRoot` is currently in flight.
    func hasInFlightStatusFetchForTesting(repoRoot: String) -> Bool {
        fetchGenerationByRepoRoot[repoRoot] != nil
    }
    #endif

    /// Merges every repository snapshot into `gitStatusByPath` and
    /// `deletedPathsByParent`, then reconciles ghost rows in loaded directories.
    /// Outer repositories merge first so a nested repository's entries win.
    private func rebuildMergedGitStatus() {
        var merged: [String: GitFileStatus] = [:]
        var deleted: [String: Set<String>] = [:]
        for repoRoot in statusByRepoRoot.keys.sorted(by: { $0.count < $1.count || ($0.count == $1.count && $0 < $1) }) {
            guard let snapshot = statusByRepoRoot[repoRoot] else { continue }
            merged.merge(snapshot.statusByPath) { _, nested in nested }
            for (parent, paths) in snapshot.deletedPathsByParent {
                deleted[GitStatusProvider.pathWithoutTrailingSlashes(parent), default: []].formUnion(paths)
            }
        }
        let mergedDeleted = deleted.mapValues { $0.sorted() }
        guard merged != gitStatusByPath || mergedDeleted != deletedPathsByParent else { return }
        gitStatusByPath = merged
        deletedPathsByParent = mergedDeleted
        rebuildGhostDirectoryIndex()
        gitStatusRevision &+= 1
        reconcileGhostNodes()
    }

    // MARK: Repository watchers (local only)

    private func startRepositoryWatchIfNeeded(repoRoot: String) {
        guard provider is LocalFileExplorerProvider,
              repositoryWatches[repoRoot] == nil,
              repositoryWatchStartTasks[repoRoot] == nil else { return }
        let context = resourceContextID, factory = repositoryWatchFactory
        repositoryWatchStartTasks[repoRoot] = Task { [weak self] in
            let watch = await factory(repoRoot)
            guard let self else {
                if let watch { await watch.stop() }
                return
            }
            self.repositoryWatchStartTasks.removeValue(forKey: repoRoot)
            guard self.resourceContextID == context,
                  self.statusByRepoRoot[repoRoot] != nil,
                  self.repositoryWatches[repoRoot] == nil,
                  let watch else {
                if let watch { await watch.stop() }
                return
            }
            self.repositoryWatches[repoRoot] = watch
            let events = watch.events
            self.repositoryWatchTasks[repoRoot] = Task { @MainActor [weak self] in
                for await _ in events {
                    guard let self, !Task.isCancelled else { break }
                    guard self.resourceContextID == context else { break }
                    self.refetchRepository(repoRoot)
                }
            }
        }
    }

    private func stopAllRepositoryWatches() {
        for task in repositoryWatchStartTasks.values { task.cancel() }
        repositoryWatchStartTasks.removeAll()
        for task in repositoryWatchTasks.values { task.cancel() }
        repositoryWatchTasks.removeAll()
        let watches = Array(repositoryWatches.values)
        repositoryWatches.removeAll()
        guard !watches.isEmpty else { return }
        Task.detached(priority: .utility) {
            for watch in watches { await watch.stop() }
        }
    }

    // MARK: Ghost rows for deleted files

    private func makeGhostNode(path: String, isDirectory: Bool) -> FileExplorerNode {
        let node = FileExplorerNode(
            name: (path as NSString).lastPathComponent,
            path: path,
            isDirectory: isDirectory,
            isGhost: true
        )
        node.resourceContextID = resourceContextID
        return node
    }

    /// Rebuilds `ghostDirectoriesByParent` from `deletedPathsByParent`: every
    /// directory on the chain from a deleted file's parent up to (excluding)
    /// the explorer root, keyed by its own parent. A whole deleted directory
    /// is missing from its parent's listing, so the parent needs a ghost
    /// directory row that expands into the ghost files; directories that
    /// still exist are listed for real and never consulted here.
    private func rebuildGhostDirectoryIndex() {
        var index: [String: Set<String>] = [:]
        let root = GitStatusProvider.pathWithoutTrailingSlashes(rootPath)
        guard !root.isEmpty else {
            ghostDirectoriesByParent = [:]
            return
        }
        for parent in deletedPathsByParent.keys {
            var current = parent
            while GitStatusProvider.path(current, isContainedIn: root), current != root {
                let grandparent = (current as NSString).deletingLastPathComponent
                index[grandparent, default: []].insert(current)
                current = grandparent
            }
        }
        ghostDirectoriesByParent = index
    }

    private func isGhostPathVisible(_ path: String) -> Bool {
        showHiddenFiles || !(path as NSString).lastPathComponent.hasPrefix(".")
    }

    /// Deleted file paths that belong in `directory` and are not backed by a listed entry.
    private func ghostFilePaths(in directory: String, excluding realPaths: Set<String>) -> [String] {
        (deletedPathsByParent[GitStatusProvider.pathWithoutTrailingSlashes(directory)] ?? []).filter { path in
            !realPaths.contains(path) && isGhostPathVisible(path)
        }
    }

    /// Deleted directories directly under `directory` that no listed entry has
    /// taken back, sorted.
    private func ghostDirectoryPaths(in directory: String, excluding realPaths: Set<String>) -> [String] {
        (ghostDirectoriesByParent[GitStatusProvider.pathWithoutTrailingSlashes(directory)] ?? [])
            .filter { !realPaths.contains($0) && isGhostPathVisible($0) }
            .sorted()
    }

    /// Every ghost path `directory` should show, including the files below its
    /// ghost directories, sorted. The comparison key for reconciliation.
    private func wantedGhostPaths(in directory: String, excluding realPaths: Set<String>) -> [String] {
        var paths = ghostFilePaths(in: directory, excluding: realPaths)
        for ghostDirectory in ghostDirectoryPaths(in: directory, excluding: realPaths) {
            paths.append(ghostDirectory)
            paths += wantedGhostPaths(in: ghostDirectory, excluding: [])
        }
        return paths.sorted()
    }

    /// The paths of `ghosts` and, recursively, of their ghost children, sorted.
    private func flattenedGhostPaths(_ ghosts: [FileExplorerNode]) -> [String] {
        var paths: [String] = []
        for ghost in ghosts {
            paths.append(ghost.path)
            paths += flattenedGhostPaths(ghost.children ?? [])
        }
        return paths.sorted()
    }

    /// The rows `directory` displays: `real` listed entries plus a ghost row for
    /// every deleted path no listed entry has taken back, sorted with the shared
    /// comparator. Ghost nodes in `existingGhosts` are reused so outline
    /// identity stays stable across reconciliations; a reused ghost directory
    /// gets its children rebuilt the same way.
    private func displayChildren(
        real: [FileExplorerNode], directory: String, reusingGhosts existingGhosts: [FileExplorerNode] = []
    ) -> [FileExplorerNode] {
        var existingByPath: [String: FileExplorerNode] = [:]
        for ghost in existingGhosts { existingByPath[ghost.path] = ghost }
        let realPaths = Set(real.map(\.path))
        let ghostFiles = ghostFilePaths(in: directory, excluding: realPaths).map { path in
            existingByPath[path].flatMap { $0.isDirectory ? nil : $0 } ?? makeGhostNode(path: path, isDirectory: false)
        }
        let ghostDirectories = ghostDirectoryPaths(in: directory, excluding: realPaths).map { path in
            let node = existingByPath[path].flatMap { $0.isDirectory ? $0 : nil }
                ?? makeGhostNode(path: path, isDirectory: true)
            node.children = displayChildren(real: [], directory: path, reusingGhosts: node.children ?? [])
            return node
        }
        return FileExplorerNode.sorted(real + ghostFiles + ghostDirectories)
    }

    /// Returns `children` with ghost rows added or removed to match the current
    /// deleted-path index, or `children` itself when nothing changed.
    private func childrenReconcilingGhosts(_ children: [FileExplorerNode], directory: String, changed: inout Bool) -> [FileExplorerNode] {
        let real = children.filter { !$0.isGhost }
        let existingGhosts = children.filter(\.isGhost)
        let wanted = wantedGhostPaths(in: directory, excluding: Set(real.map(\.path)))
        guard wanted != flattenedGhostPaths(existingGhosts) else { return children }
        changed = true
        return displayChildren(real: real, directory: directory, reusingGhosts: existingGhosts)
    }

    /// Adds or removes ghost rows in every loaded directory after the merged
    /// status changed, bumping `contentRevision` when the tree changed shape.
    private func reconcileGhostNodes() {
        var changed = false
        if rootListingLoaded, !rootPath.isEmpty {
            let reconciled = childrenReconcilingGhosts(rootNodes, directory: rootPath, changed: &changed)
            if changed { rootNodes = reconciled }
        }
        for node in nodesByPath.values where node.isDirectory && !node.isGhost {
            guard let children = node.children,
                  node.resourceContextID == nil || node.resourceContextID == resourceContextID else { continue }
            var nodeChanged = false
            let reconciled = childrenReconcilingGhosts(children, directory: node.path, changed: &nodeChanged)
            if nodeChanged {
                node.children = reconciled
                changed = true
            }
        }
        if changed {
            contentRevision &+= 1
            objectWillChange.send()
        }
    }

    func materializeRemoteFileForPreview(
        path: String,
        expectedWorkspaceRootIdentity: UUID? = nil
    ) async throws -> URL {
        // `DisableFileTransfer` (MDM): a preview copies the file off the remote
        // host onto this Mac, which is a cmux-mediated download.
        guard !ManagedFileTransferPolicy.isDisabled else {
            throw ManagedFileTransferPolicy.refusalError()
        }
        guard expectedWorkspaceRootIdentity == nil || workspaceRootIdentity == expectedWorkspaceRootIdentity,
              let remoteProvider = provider as? SSHFileExplorerProvider else {
            throw FileExplorerError.providerUnavailable
        }
        let cacheURL = Self.remotePreviewCacheURL(
            displayTarget: remoteProvider.displayTarget,
            remotePath: path
        )
        try await remoteProvider.downloadFile(path: path, to: cacheURL)
        guard expectedWorkspaceRootIdentity == nil ||
              (workspaceRootIdentity == expectedWorkspaceRootIdentity && provider === remoteProvider) else {
            try? FileManager.default.removeItem(at: cacheURL)
            throw FileExplorerError.providerUnavailable
        }
        return cacheURL
    }

    private func updateDirectoryWatcher() {
        if provider is LocalFileExplorerProvider, !rootPath.isEmpty {
            guard directoryWatchPath != rootPath || directoryWatcher == nil else { return }
            stopDirectoryWatcher()
            // Preserve the previous 0.3s coalescing as a leading-edge throttle.
            let watcher = FileWatcher(path: rootPath, throttle: .milliseconds(300))
            directoryWatcher = watcher
            directoryWatchPath = rootPath
            let events = watcher.events
            directoryWatchTask = Task { @MainActor [weak self] in
                for await _ in events {
                    guard let self else { break }
                    self.reload()
                    self.refreshRootRepositoryStatus()
                }
            }
        } else {
            stopDirectoryWatcher()
        }
    }

    /// Cancels the directory-watch consumer and drops the watcher; the watcher's
    /// deinit cancels its `DispatchSource`s synchronously.
    private func stopDirectoryWatcher() {
        directoryWatchTask?.cancel()
        directoryWatchTask = nil
        directoryWatcher = nil
        directoryWatchPath = nil
    }

    func setProvider(_ newProvider: FileExplorerProvider?, reloadIfAvailable: Bool = true) {
        #if DEBUG
        NSLog("[FileExplorer] setProvider: \(type(of: newProvider).self) available=\(newProvider?.isAvailable ?? false)")
        #endif
        let providerChanged: Bool
        switch (provider, newProvider) {
        case let (current?, next?): providerChanged = current !== next
        case (nil, nil): providerChanged = false
        default: providerChanged = true
        }
        if providerChanged { resetResourceContext(preservingNavigation: true) }
        provider = newProvider
        // Re-expand previously expanded nodes if provider becomes available
        if reloadIfAvailable, newProvider?.isAvailable == true {
            reload()
        }
    }

    #if DEBUG
    func setProviderForTesting(_ newProvider: FileExplorerProvider?, reloadIfAvailable: Bool = true) {
        setProvider(newProvider, reloadIfAvailable: reloadIfAvailable)
    }
    #endif

    func reload() {
        #if DEBUG
        NSLog("[FileExplorer] reload() path=\(rootPath) provider=\(type(of: provider).self)")
        #endif
        contentRevision &+= 1
        cancelAllLoads()
        rootNodes = []
        nodesByPath = [:]
        rootListingLoaded = false
        forgetNegativeRepositoryProbes()
        guard !rootPath.isEmpty, provider != nil else { return }
        isRootLoading = true
        let path = rootPath
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadChildren(for: nil, at: path)
        }
        loadTasks[rootPath] = task
    }

    func expand(node: FileExplorerNode) {
        guard node.resourceContextID == nil || node.resourceContextID == resourceContextID, node.isDirectory else { return }
        if node.isGhost {
            // A ghost directory already carries the ghost rows the store
            // synthesized for it; there is nothing on disk to list.
            guard node.isExpandable else { return }
            expandedPaths.insert(node.path)
            objectWillChange.send()
            return
        }
        expandedPaths.insert(node.path)
        if let children = node.children {
            // Already listed (e.g. by a silent prefetch, or before a reload dropped
            // a cached negative): re-run the cheap repository pre-filter.
            discoverNestedRepositoryIfNeeded(
                directory: node.path,
                listingNames: children.filter { !$0.isGhost }.map(\.name)
            )
        }
        if node.children == nil, loadTasks[node.path] == nil, !loadingPaths.contains(node.path) {
            node.isLoading = true
            node.error = nil
            objectWillChange.send()
            let nodePath = node.path
            let task = Task { [weak self] in
                guard let self else { return }
                await self.loadChildren(for: node, at: nodePath)
            }
            loadTasks[node.path] = task
        }
    }

    func collapse(node: FileExplorerNode) {
        expandedPaths.remove(node.path)
        if pendingDescendIntoFirstChildPath == node.path {
            pendingDescendIntoFirstChildPath = nil
        }
        objectWillChange.send()
    }

    func isExpanded(_ node: FileExplorerNode) -> Bool {
        expandedPaths.contains(node.path)
    }

    func select(node: FileExplorerNode?) {
        let path = node?.path
        let paths = path.map { Set([$0]) } ?? []
        guard selectedPath != path || selectedPaths != paths else { return }
        selectedPath = path
        selectedPaths = paths
        if path != pendingDescendIntoFirstChildPath {
            pendingDescendIntoFirstChildPath = nil
        }
    }

    func select(nodes: [FileExplorerNode], anchor: FileExplorerNode?) {
        let paths = Set(nodes.map(\.path))
        let path = anchor?.path ?? nodes.first?.path
        guard selectedPath != path || selectedPaths != paths else { return }
        selectedPath = path
        selectedPaths = paths
        if path != pendingDescendIntoFirstChildPath {
            pendingDescendIntoFirstChildPath = nil
        }
    }

    func requestDescendIntoFirstChild(of node: FileExplorerNode) {
        guard node.resourceContextID == nil || node.resourceContextID == resourceContextID, node.isDirectory else { return }
        selectedPath = node.path
        selectedPaths = [node.path]
        pendingDescendIntoFirstChildPath = node.path
        expand(node: node)
    }

    func prefetchChildren(for node: FileExplorerNode) {
        guard node.resourceContextID == nil || node.resourceContextID == resourceContextID, node.isDirectory, !node.isGhost, node.children == nil, !loadingPaths.contains(node.path) else { return }
        // Debounce: only prefetch if hover persists for 200ms
        let path = node.path
        let scheduler = prefetchSchedulers[path] ?? MainActorDeferredActionScheduler()
        prefetchSchedulers[path] = scheduler
        scheduler.schedule(after: .milliseconds(200)) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, node.children == nil, !self.loadingPaths.contains(path) else { return }
                // Silent prefetch: don't show loading indicator
                await self.loadChildren(for: node, at: path, silent: true)
            }
        }
    }

    func cancelPrefetch(for node: FileExplorerNode) {
        prefetchSchedulers[node.path]?.cancel()
        prefetchSchedulers.removeValue(forKey: node.path)
    }

    /// Called when SSH provider becomes available after being unavailable.
    /// Re-hydrates expanded nodes that were waiting.
    func hydrateExpandedNodes() {
        guard let provider, provider.isAvailable, !expandedPaths.isEmpty else { return }
        #if DEBUG
        NSLog("[FileExplorer] hydrateExpandedNodes: \(expandedPaths.count) paths to hydrate")
        #endif
        reload()
    }

    // MARK: - Private

    @MainActor
    private func loadChildren(for parentNode: FileExplorerNode?, at path: String, silent: Bool = false) async {
        guard parentNode?.resourceContextID == nil || parentNode?.resourceContextID == resourceContextID else { return }
        // A load cancelled by cancelAllLoads (e.g. a root reload during an SSH provider swap) must not
        // reach provider.listDirectory: the provider may have been replaced, so a stale in-flight load
        // would list the old path through the new transport. Bail before any listing.
        guard !Task.isCancelled else { return }
        guard let provider else { return }

        if !silent {
            loadingPaths.insert(path)
            parentNode?.error = nil
            objectWillChange.send()
        }

        do {
            let entries = try await provider.listDirectory(path: path, showHidden: showHiddenFiles)
            try Task.checkCancellation()
            let listed = entries.map { entry in
                let node = FileExplorerNode(name: entry.name, path: entry.path, isDirectory: entry.isDirectory)
                node.resourceContextID = resourceContextID
                nodesByPath[entry.path] = node
                return node
            }
            // Files git reports as deleted are gone from disk; keep them visible
            // as ghost rows unless a listed entry has taken the path back.
            let children = displayChildren(real: listed, directory: path)

            if let parentNode {
                parentNode.children = children
                parentNode.isLoading = false
                parentNode.error = nil
                if pendingDescendIntoFirstChildPath == parentNode.path {
                    let path = children.first?.path ?? parentNode.path
                    selectedPath = path
                    selectedPaths = [path]
                    pendingDescendIntoFirstChildPath = nil
                }
            } else {
                rootNodes = children
                rootListingLoaded = true
                isRootLoading = false
                setRootStatusMessage(nil)
                if selectedPath == nil {
                    selectedPath = children.first?.path
                    selectedPaths = selectedPath.map { Set([$0]) } ?? []
                }
            }
            loadingPaths.remove(path)
            loadTasks.removeValue(forKey: path)
            objectWillChange.send()

            // Nested repositories are discovered from their own listing; the root
            // repository is resolved by refreshGitStatus().
            if parentNode != nil {
                discoverNestedRepositoryIfNeeded(directory: path, listingNames: entries.map(\.name))
            }

            // Auto-expand children that were previously expanded
            for child in children where child.isDirectory && expandedPaths.contains(child.path) {
                child.isLoading = true
                objectWillChange.send()
                let childPath = child.path
                let childTask = Task { [weak self] in
                    guard let self else { return }
                    await self.loadChildren(for: child, at: childPath)
                }
                loadTasks[child.path] = childTask
            }
        } catch {
            if !Task.isCancelled {
                if let parentNode {
                    parentNode.isLoading = false
                    parentNode.error = error.localizedDescription
                } else {
                    isRootLoading = false
                    setRootStatusMessage(error.localizedDescription)
                }
                loadingPaths.remove(path)
                loadTasks.removeValue(forKey: path)
                objectWillChange.send()
            }
        }
    }

    private func cancelAllLoads() {
        for (_, task) in loadTasks {
            task.cancel()
        }
        loadTasks.removeAll()
        loadingPaths.removeAll()
        pendingDescendIntoFirstChildPath = nil
        for scheduler in prefetchSchedulers.values {
            scheduler.cancel()
        }
        prefetchSchedulers.removeAll()
        isRootLoading = false
    }

    private static func remotePreviewCacheURL(displayTarget: String, remotePath: String) -> URL {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remote-file-previews", isDirectory: true)
        let target = sanitizedCacheComponent(displayTarget)
        let remote = sanitizedCacheComponent(remotePath)
        let basename = URL(fileURLWithPath: remotePath).lastPathComponent
        let filename = basename.isEmpty ? remote : "\(remote)-\(basename)"
        return cacheRoot
            .appendingPathComponent(target, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    private static func sanitizedCacheComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let candidate = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return candidate.isEmpty ? UUID().uuidString : String(candidate.prefix(160))
    }

    deinit {
        remoteHomeResolutionTask?.cancel()
        directoryWatchTask?.cancel()
        for task in repositoryWatchStartTasks.values { task.cancel() }
        for task in repositoryWatchTasks.values { task.cancel() }
        // The watches' underlying watchers tear down in their own deinit once
        // these references drop; no stop() call is needed here.
    }
}
