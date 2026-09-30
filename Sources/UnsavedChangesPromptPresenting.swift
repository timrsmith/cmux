import Foundation

/// Shows the unsaved-changes prompt and its save-failure follow-up.
///
/// ``UnsavedChangesAlertPresenter`` is the AppKit implementation; tests inject
/// a recording fake so no alert is ever shown.
@MainActor
protocol UnsavedChangesPromptPresenting: AnyObject {
    /// Presents Save / Don't Save / Cancel for one close action and returns the answer.
    func presentUnsavedChangesPrompt(_ prompt: UnsavedChangesPrompt) -> UnsavedChangesPromptResponse

    /// Tells the user a close-time save failed and that nothing was closed.
    func presentUnsavedChangesSaveFailure(_ error: any Error)
}
