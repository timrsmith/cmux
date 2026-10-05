import Foundation

/// A file and line range the diff viewer hands to the agent prompt, written
/// the way agents and editors read it: `path:line`, or `path:start-end` for a
/// range. The lines are normalized so a range selected upwards reads the same
/// as one selected downwards.
struct PromptLineReference: Equatable {
    let filePath: String
    let startLine: Int
    let endLine: Int

    init(filePath: String, startLine: Int, endLine: Int) {
        self.filePath = filePath
        self.startLine = min(startLine, endLine)
        self.endLine = max(startLine, endLine)
    }

    /// The reference followed by one space, so the question typed after it
    /// does not run into the line number.
    var promptText: String {
        let lines = endLine > startLine ? "\(startLine)-\(endLine)" : "\(startLine)"
        return "\(filePath):\(lines) "
    }
}
