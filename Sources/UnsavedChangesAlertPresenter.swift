import AppKit

/// The AppKit alert behind ``UnsavedChangesPromptPresenting``.
///
/// Buttons follow the platform layout for a save prompt: Save is the default
/// (Return), Don't Save also answers to ⌘D, Cancel answers to Escape. Long file
/// lists scroll inside the alert through ``CmuxAlertContent``.
@MainActor
final class UnsavedChangesAlertPresenter: UnsavedChangesPromptPresenting {
    private let presentingWindowProvider: @MainActor () -> NSWindow?

    init(
        presentingWindowProvider: @escaping @MainActor () -> NSWindow? = {
            NSApp.cmuxMainWindowForModalPresentation()
        }
    ) {
        self.presentingWindowProvider = presentingWindowProvider
    }

    func presentUnsavedChangesPrompt(_ prompt: UnsavedChangesPrompt) -> UnsavedChangesPromptResponse {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = prompt.title

        let saveButton = alert.addButton(
            withTitle: String(localized: "dialog.unsavedChanges.save", defaultValue: "Save")
        )
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = []
        alert.window.defaultButtonCell = saveButton.cell as? NSButtonCell
        alert.window.initialFirstResponder = saveButton

        let cancelButton = alert.addButton(
            withTitle: String(localized: "common.cancel", defaultValue: "Cancel")
        )
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []

        let dontSaveButton = alert.addButton(
            withTitle: String(localized: "common.dontSave", defaultValue: "Don't Save")
        )
        dontSaveButton.keyEquivalent = "d"
        dontSaveButton.keyEquivalentModifierMask = [.command]

        let content = prompt.details.map {
            CmuxAlertContent(flattenedText: prompt.message, separatingScrollableDetails: $0)
        } ?? CmuxAlertContent(informativeText: prompt.message)

        switch alert.runCmuxModal(presentingWindow: presentingWindowProvider(), content: content) {
        case .alertFirstButtonReturn:
            return .save
        case .alertThirdButtonReturn:
            return .dontSave
        default:
            return .cancel
        }
    }

    func presentUnsavedChangesSaveFailure(_ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(
            localized: "dialog.unsavedChanges.saveFailed.title",
            defaultValue: "Save Failed"
        )
        let nothingClosed = String(
            localized: "dialog.unsavedChanges.saveFailed.message",
            defaultValue: "Nothing was closed, and your changes are still open."
        )
        alert.informativeText = "\(error.localizedDescription)\n\n\(nothingClosed)"
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        _ = alert.runCmuxModal(presentingWindow: presentingWindowProvider())
    }
}
