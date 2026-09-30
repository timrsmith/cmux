import Foundation

/// A panel whose editable buffer can diverge from the file on disk.
///
/// Close paths consult this before discarding a panel: a dirty panel
/// (`Panel.isDirty`) makes the close ask "Save changes?" regardless of the
/// close-warning settings, because losing edits is data loss rather than an
/// interrupted process.
@MainActor
protocol UnsavedChangesTracking: Panel {
    /// The file name shown in the unsaved-changes prompt.
    var unsavedChangesDisplayName: String { get }

    /// Writes the buffer to disk. Throws when the save did not land, in which
    /// case the panel remains dirty and the close is cancelled.
    func saveUnsavedChanges() async throws
}

extension UnsavedChangesTracking {
    /// The tab title, which the text editors set to the file's last path component.
    var unsavedChangesDisplayName: String { displayTitle }
}

extension UnsavedChangesTracking where Self: FilePreviewTextEditingPanel {
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

/// The error a text editor throws when a close-time save does not land.
struct UnsavedChangesSaveError: LocalizedError, Equatable {
    /// The file whose save failed.
    let fileName: String

    var errorDescription: String? {
        String(
            format: String(
                localized: "error.unsavedChanges.saveFailed",
                defaultValue: "“%@” could not be saved."
            ),
            locale: .current,
            fileName
        )
    }
}
