import Foundation

/// A panel whose editable buffer can diverge from the file on disk.
///
/// Close paths consult this before discarding a panel: a dirty panel makes the
/// close ask "Save changes?" regardless of the close-warning settings, because
/// losing edits is data loss rather than an interrupted process.
@MainActor
protocol UnsavedChangesTracking: Panel {
    /// Whether the buffer differs from what was last loaded or saved.
    var hasUnsavedChanges: Bool { get }

    /// The file name shown in the unsaved-changes prompt.
    var unsavedChangesDisplayName: String { get }

    /// Writes the buffer to disk. Throws when the save did not land, in which
    /// case the panel remains dirty and the close is cancelled.
    func saveUnsavedChanges() async throws
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
