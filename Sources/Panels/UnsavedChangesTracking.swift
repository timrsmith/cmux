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
    /// Saves the text buffer and waits for the write to settle.
    ///
    /// `saveTextContent()` starts nothing while a save is already running, so
    /// that save is awaited instead and the buffer is saved once more when it
    /// was edited after the running save started; two rounds cover that.
    /// When no write can start at all (a read-only cloud preview), the error
    /// says so rather than reporting a failed write.
    func saveUnsavedChanges() async throws {
        for _ in 0..<2 {
            guard isDirty else { return }
            if let save = saveTextContent() {
                await save.value
                guard isDirty else { return }
                throw UnsavedChangesSaveError(fileName: unsavedChangesDisplayName, reason: .writeFailed)
            }
            guard let runningSave = latestTextSaveTask else { break }
            await runningSave.value
        }
        guard isDirty else { return }
        throw UnsavedChangesSaveError(fileName: unsavedChangesDisplayName, reason: .savingUnavailable)
    }
}

/// The error a text editor throws when a close-time save does not land.
struct UnsavedChangesSaveError: LocalizedError, Equatable {
    /// Why the buffer is still unsaved.
    enum Reason: Equatable, Sendable {
        /// A write ran and did not land: the file is gone, read-only, or the
        /// disk refused it.
        case writeFailed
        /// No write could start: the panel cannot save at all, as a cloud
        /// preview of a remote file cannot.
        case savingUnavailable
    }

    /// The file whose save did not land.
    let fileName: String
    let reason: Reason

    init(fileName: String, reason: Reason = .writeFailed) {
        self.fileName = fileName
        self.reason = reason
    }

    var errorDescription: String? {
        let format: String
        switch reason {
        case .writeFailed:
            format = String(
                localized: "error.unsavedChanges.saveFailed",
                defaultValue: "“%@” could not be saved."
            )
        case .savingUnavailable:
            format = String(
                localized: "error.unsavedChanges.savingUnavailable",
                defaultValue: "Saving isn’t available for “%@”."
            )
        }
        return String(format: format, locale: .current, fileName)
    }
}
