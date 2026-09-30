import Foundation

extension MarkdownPanel: UnsavedChangesTracking {
    var hasUnsavedChanges: Bool { isDirty }

    var unsavedChangesDisplayName: String { (filePath as NSString).lastPathComponent }

    /// Saves the text buffer and waits for the write to settle. A save that is
    /// already in flight is awaited instead of being restarted.
    func saveUnsavedChanges() async throws {
        guard isDirty else { return }
        if let save = saveTextContent() {
            await save.value
        } else if let inFlightSave = latestTextSaveTask {
            await inFlightSave.value
        }
        guard !isDirty else {
            throw UnsavedChangesSaveError(fileName: unsavedChangesDisplayName)
        }
    }
}
