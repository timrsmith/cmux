import Foundation

/// The answer a user gives to the unsaved-changes prompt.
enum UnsavedChangesPromptResponse: Equatable, Sendable {
    case save
    case dontSave
    case cancel
}

/// The copy of one unsaved-changes prompt: one alert per close action, not per file.
struct UnsavedChangesPrompt: Equatable, Sendable {
    /// "Save changes to “name”?" for one file, "Save changes to N files?" for several.
    let title: String
    /// The fixed explanation, followed by the file list when several files are dirty.
    let message: String
    /// The bullet list of file names, or `nil` for a single file whose name is in the title.
    let details: String?
    /// The dirty file names in close order.
    let fileNames: [String]
}

/// Pure decision for closing panels that may hold unsaved edits: which prompt
/// (if any) to show and how an answer maps onto the close.
///
/// Holds no AppKit so it is testable without a window; the alert itself lives
/// in ``UnsavedChangesAlertPresenter``.
struct UnsavedChangesClosePlan: Equatable, Sendable {
    /// What the close should do after the prompt.
    enum Outcome: Equatable, Sendable {
        /// Continue closing without touching disk.
        case proceed
        /// Save every dirty panel, then continue closing; a save failure cancels.
        case saveThenProceed
        /// Keep everything open.
        case cancel
    }

    /// The dirty file names, in close order.
    let fileNames: [String]

    init(fileNames: [String]) {
        self.fileNames = fileNames
    }

    /// Whether the close has anything to ask about.
    var requiresPrompt: Bool { !fileNames.isEmpty }

    /// The prompt never offers "Don't ask again": it guards data, not a preference.
    var offersDontAskAgain: Bool { false }

    /// Whether the prompt's answer stands in for the close-warning confirmation
    /// of the same action.
    ///
    /// Save and Don't Save both confirm the close, so the `CloseTabWarningStore`
    /// prompt ("Close tab?", "Close workspace?", "Close window?", "Quit cmux?")
    /// must not ask a second time; Cancel ends the action instead.
    func confirmsClose(for response: UnsavedChangesPromptResponse) -> Bool {
        outcome(for: response) != .cancel
    }

    /// The prompt for these files, or `nil` when nothing is dirty.
    var prompt: UnsavedChangesPrompt? {
        guard let first = fileNames.first else { return nil }
        if fileNames.count == 1 {
            return UnsavedChangesPrompt(
                title: String(
                    format: String(
                        localized: "dialog.unsavedChanges.title.one",
                        defaultValue: "Save changes to “%@”?"
                    ),
                    locale: .current,
                    first
                ),
                message: String(
                    localized: "dialog.unsavedChanges.message",
                    defaultValue: "Your changes will be lost if you don't save them."
                ),
                details: nil,
                fileNames: fileNames
            )
        }
        let details = fileNames.map { "• \($0)" }.joined(separator: "\n")
        return UnsavedChangesPrompt(
            title: String(
                format: String(
                    localized: "dialog.unsavedChanges.title.other",
                    defaultValue: "Save changes to %lld files?"
                ),
                locale: .current,
                Int64(fileNames.count)
            ),
            message: String(
                format: String(
                    localized: "dialog.unsavedChanges.messageList",
                    defaultValue: "Your changes to these files will be lost if you don't save them:\n%@"
                ),
                locale: .current,
                details
            ),
            details: details,
            fileNames: fileNames
        )
    }

    /// Maps the user's answer onto the close.
    func outcome(for response: UnsavedChangesPromptResponse) -> Outcome {
        switch response {
        case .save:
            return .saveThenProceed
        case .dontSave:
            return .proceed
        case .cancel:
            return .cancel
        }
    }
}
