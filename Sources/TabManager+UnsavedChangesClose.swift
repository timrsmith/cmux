import Foundation

extension TabManager {
    /// Gate for workspace-level closes: asks about unsaved edits anywhere in
    /// `workspaces` first and re-issues the close through `retry`.
    ///
    /// - Returns: `true` when the caller must stop now because the prompt took
    ///   the close over; `false` when nothing is dirty and the caller continues.
    func deferWorkspaceCloseForUnsavedChanges(
        _ workspaces: [Workspace],
        retry: @escaping @MainActor () -> Void
    ) -> Bool {
        unsavedChangesCloseConfirmation.deferCloseIfNeeded(
            for: workspaces.flatMap(\.closablePanelsIncludingDock),
            retry: retry
        )
    }
}
