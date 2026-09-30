import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Records every unsaved-changes prompt and answers from a script, so no alert
/// is ever shown in tests.
@MainActor
final class RecordingUnsavedChangesPresenter: UnsavedChangesPromptPresenting {
    private(set) var prompts: [UnsavedChangesPrompt] = []
    private(set) var saveFailures: [String] = []
    /// Answers consumed in order; an exhausted script answers Cancel.
    var responses: [UnsavedChangesPromptResponse]
    /// Runs while the prompt is "up", before the answer is returned: the point
    /// between the user's click and the close-time save that follows it.
    var onPrompt: (@MainActor () -> Void)?

    init(responses: [UnsavedChangesPromptResponse] = []) {
        self.responses = responses
    }

    func presentUnsavedChangesPrompt(_ prompt: UnsavedChangesPrompt) -> UnsavedChangesPromptResponse {
        prompts.append(prompt)
        onPrompt?()
        guard !responses.isEmpty else { return .cancel }
        return responses.removeFirst()
    }

    func presentUnsavedChangesSaveFailure(_ error: any Error) {
        saveFailures.append(error.localizedDescription)
    }
}

enum UnsavedChangesTestFiles {
    /// A new file in the temporary directory holding `contents`; the caller removes it.
    static func temporaryFile(extension fileExtension: String, contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func temporaryMarkdownFile(contents: String) throws -> URL {
        try temporaryFile(extension: "md", contents: contents)
    }

    static func temporaryTextFile(contents: String) throws -> URL {
        try temporaryFile(extension: "txt", contents: contents)
    }
}

/// Text editors opened on a fresh temporary file with their buffer loaded, the
/// state a visible editor is in by the time a close is requested.
@MainActor
enum UnsavedChangesTestPanels {
    /// A Markdown editor on a new file holding `contents`. `open` builds the
    /// panel for the file's path: a standalone panel by default, or one a
    /// workspace owns when the caller opens it there.
    static func makeLoadedMarkdownPanel(
        contents: String = "# Original\n",
        open: ((String) throws -> MarkdownPanel)? = nil
    ) async throws -> (panel: MarkdownPanel, url: URL) {
        let url = try UnsavedChangesTestFiles.temporaryMarkdownFile(contents: contents)
        let panel = try open?(url.path) ?? MarkdownPanel(workspaceId: UUID(), filePath: url.path)
        if let load = panel.loadTextContent() {
            await load.value
        }
        return (panel, url)
    }

    /// A native text editor on a new file holding `contents`, without a file
    /// watcher. `open` builds the panel for the file's path when a test needs
    /// its own saver or loader.
    static func makeLoadedFilePreviewPanel(
        contents: String = "original text",
        open: ((String) throws -> FilePreviewPanel)? = nil
    ) async throws -> (panel: FilePreviewPanel, url: URL) {
        let url = try UnsavedChangesTestFiles.temporaryTextFile(contents: contents)
        let panel = try open?(url.path) ?? FilePreviewPanel(
            workspaceId: UUID(),
            filePath: url.path,
            startFileWatcher: false,
            modeResolver: { _ in .text }
        )
        await panel.loadTextContent().value
        return (panel, url)
    }
}
