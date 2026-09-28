import CmuxSettings
import Foundation

/// How the app launches the bundled `cmux` CLI for the diff viewer. The
/// Cmd+Shift+D pane (`cmux diff`) and the right sidebar's Changes panel
/// (`cmux __diff-viewer-page`) share one contract: the bundled executable,
/// the socket the running app serves, `--cwd`/`--workspace` targeting, and
/// the `CMUX_*` identity environment the CLI reads back.
struct DiffViewerCLILaunch: Sendable {
    let cliURL: URL
    let socketPath: String

    /// The bundled CLI and the running app's socket; nil when the CLI is not
    /// installed in the bundle.
    @MainActor
    static func current() -> DiffViewerCLILaunch? {
        guard let cliURL = CLIForwardingLaunchRouter.bundledCLIURL() else { return nil }
        return DiffViewerCLILaunch(
            cliURL: cliURL,
            socketPath: TerminalController.shared.activeSocketPath(
                preferredPath: SocketControlSettings.socketPath()
            )
        )
    }

    /// A not-yet-run process for `cmux --socket <socket> <command> --cwd <cwd>
    /// --workspace <id> [--surface <id>] <arguments>`. The environment names the
    /// same socket, CLI path, workspace and surface, and drops the inherited
    /// `CMUX_SOCKET`/`CMUX_SURFACE_ID` so a dev build launched from another
    /// cmux never targets its parent.
    func makeProcess(
        command: String,
        cwd: String,
        workspaceId: UUID,
        surfaceId: UUID? = nil,
        arguments: [String] = []
    ) -> Process {
        let process = Process()
        process.executableURL = cliURL
        var processArguments = [
            "--socket", socketPath,
            command,
            "--cwd", cwd,
            "--workspace", workspaceId.uuidString,
        ]
        if let surfaceId {
            processArguments.append(contentsOf: ["--surface", surfaceId.uuidString])
        }
        processArguments.append(contentsOf: arguments)
        process.arguments = processArguments

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_BUNDLED_CLI_PATH"] = cliURL.path
        environment["CMUX_WORKSPACE_ID"] = workspaceId.uuidString
        if let surfaceId {
            environment["CMUX_SURFACE_ID"] = surfaceId.uuidString
        } else {
            environment.removeValue(forKey: "CMUX_SURFACE_ID")
        }
        environment.removeValue(forKey: "CMUX_SOCKET")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        return process
    }
}
