import Foundation

extension CMUXCLI {
    /// Hidden verb behind the right sidebar's Changes panel. Writes the same
    /// diff viewer document `cmux diff --unstaged --cwd <repo>` would open,
    /// then prints its session instead of calling `browser.open_split`:
    ///
    /// ```json
    /// {"url": "cmux-diff-viewer://<token>/<page>",
    ///  "allowed_files": [{"request_path": ..., "file_path": ..., "mime_type": ...}],
    ///  "reloadable": true}
    /// ```
    ///
    /// The app registers `allowed_files` under the URL's host (the capability
    /// token) exactly like the `browser.open_split` trust path and loads `url`
    /// in a docked web view. `reloadable` reports whether a `reload()`
    /// recomputes the diff (typed sidecar session) or the page is a static
    /// snapshot to regenerate. Stdout carries only this document.
    func runDiffViewerPageCommand(commandArgs: [String], socketPath: String) throws {
        let usage = "Usage: cmux __diff-viewer-page --cwd <repository path> [--workspace <id|ref|index>]"
        // Same option grammar as `cmux diff`, restricted to what the panel
        // sends; everything else is rejected so this stays one document shape.
        let parsedArgs = try parseDiffArguments(commandArgs)
        guard parsedArgs.inputs.isEmpty else {
            throw CLIError(message: "__diff-viewer-page does not accept a patch file. \(usage)")
        }
        if let source = parsedArgs.source, source != .unstaged {
            throw CLIError(message: "__diff-viewer-page only renders the unstaged diff, not \(source.optionName). \(usage)")
        }
        let unsupportedFlags: [(name: String, present: Bool)] = [
            ("--window", parsedArgs.window != nil),
            ("--surface", parsedArgs.surface != nil),
            ("--session", parsedArgs.sessionId != nil),
            ("--focus", parsedArgs.focus != nil),
            ("--no-focus", parsedArgs.noFocus),
            ("--title", parsedArgs.title != nil),
            ("--layout", parsedArgs.layout != nil),
            ("--font-size", parsedArgs.fontSize != nil),
            ("--base", parsedArgs.branchBase != nil),
        ]
        if let flag = unsupportedFlags.first(where: { $0.present }) {
            throw CLIError(message: "__diff-viewer-page does not accept \(flag.name). \(usage)")
        }
        guard let cwd = normalizedDiffSourceValue(parsedArgs.cwd) else {
            throw CLIError(message: "__diff-viewer-page requires --cwd <repository path>. \(usage)")
        }
        let repoRoot = try gitRepoRoot(startingAt: resolvePath(cwd))

        // Workspace resolution matches `cmux diff`: an explicit handle, else
        // the caller's workspace from the environment. The app always passes
        // a UUID, which resolves without touching the socket.
        var context = DiffSourceContext(
            workspaceId: nil,
            surfaceId: nil,
            sessionId: nil,
            repoRoot: repoRoot,
            branchBaseRef: nil,
            restrictsRepositoryOptionsToSelected: true
        )
        let workspaceRaw = parsedArgs.workspace ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        if let workspaceHandle = normalizedDiffSourceValue(workspaceRaw) {
            if UUID(uuidString: workspaceHandle) != nil {
                context.workspaceId = workspaceHandle
            } else {
                let client = try connectClient(socketPath: socketPath, explicitPassword: nil, launchIfNeeded: false)
                defer { client.close() }
                let normalized = try normalizeWorkspaceHandle(workspaceHandle, client: client)
                context.workspaceId = try canonicalDiffSourceContext(
                    workspaceHandle: normalized,
                    surfaceHandle: nil,
                    windowHandle: nil,
                    client: client
                ).workspaceId
            }
        }

        let resolvedLayout = try resolveDiffViewerLayout(rawLayout: nil)
        let appearance = diffViewerAppearance(socketPath: socketPath, fontSizeOverride: nil)
        let runtime = diffViewerRuntime(socketPath: socketPath)
        let viewer = try writeDiffViewer(
            rawInput: nil,
            source: .unstaged,
            titleOverride: nil,
            layout: resolvedLayout.layout,
            layoutSource: resolvedLayout.source,
            appearance: appearance,
            context: context,
            runtime: runtime
        )
        // No split to navigate, so finish any deferred Git work inline before
        // reporting the document the panel should load.
        let completed = try completeDeferredDiffViewer(viewer)

        let payload: [String: Any] = [
            "url": completed.url.absoluteString,
            "allowed_files": completed.allowedFiles.map(\.jsonObject),
            "reloadable": diffViewerUsesTypedSidecar(runtime: runtime),
        ]
        print(jsonString(payload))
    }
}
