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

    init(responses: [UnsavedChangesPromptResponse] = []) {
        self.responses = responses
    }

    func presentUnsavedChangesPrompt(_ prompt: UnsavedChangesPrompt) -> UnsavedChangesPromptResponse {
        prompts.append(prompt)
        guard !responses.isEmpty else { return .cancel }
        return responses.removeFirst()
    }

    func presentUnsavedChangesSaveFailure(_ error: any Error) {
        saveFailures.append(error.localizedDescription)
    }
}

enum UnsavedChangesTestFiles {
    static func temporaryMarkdownFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("md")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func temporaryTextFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
