import Foundation

extension TabManager {
    /// Closes a socket/API-targeted workspace without an interactive veto,
    /// discarding any unsaved edits. Internal teardown (a remote session that
    /// ended, a window closing its last mirror) calls this directly; automation
    /// goes through ``closeWorkspaceNonInteractively(_:force:recordHistory:allowPinned:)``,
    /// which refuses first.
    ///
    /// Closing a window's last workspace means closing the window. A remote-tmux
    /// mirror is detached from its local owner first so a socket close never maps
    /// to the explicit remote-session kill path.
    @discardableResult
    func closeWorkspaceNonInteractively(
        _ workspace: Workspace,
        recordHistory: Bool = true,
        allowPinned: Bool = false
    ) -> Bool {
        guard canCloseWorkspace(workspace, allowPinned: allowPinned),
              tabs.contains(where: { $0.id == workspace.id }) else { return false }
        guard tabs.count == 1 else {
            closeWorkspace(workspace, recordHistory: recordHistory)
            return !tabs.contains(where: { $0.id == workspace.id })
        }
        guard let appDelegate = AppDelegate.shared,
              let windowId = appDelegate.windowId(for: self) else { return false }
        if workspace.isRemoteTmuxMirror {
            appDelegate.remoteTmuxController.detachMirrorWorkspaceKeptOpenLocally(workspaceId: workspace.id)
        }
        guard appDelegate.closeMainWindow(windowId: windowId, recordHistory: recordHistory) else {
            return false
        }
        return true
    }

    /// The automation close: the socket's `workspace.close`, the legacy
    /// `close_workspace`, the mobile companion and AppleScript. Unless `force`,
    /// a workspace holding an editor with unsaved edits is refused and nothing
    /// closes; with `force` it discards them like the teardown form above.
    func closeWorkspaceNonInteractively(
        _ workspace: Workspace,
        force: Bool,
        recordHistory: Bool = true,
        allowPinned: Bool = false
    ) -> NonInteractiveCloseOutcome {
        if !force, let refusal = unsavedChangesRefusal(forClosing: [workspace]) {
            return .refused(refusal)
        }
        return closeWorkspaceNonInteractively(workspace, recordHistory: recordHistory, allowPinned: allowPinned)
            ? .closed
            : .failed
    }

    /// The refusal a non-interactive close of `workspaces` must return, or
    /// `nil` when nothing in them holds unsaved edits. Each workspace's Dock
    /// counts, and when the close takes every workspace of this window (so the
    /// window closes too) the window Dock's editors count as well, mirroring
    /// `AppDelegate.unsavedChangesCandidatePanels(in:)`.
    func unsavedChangesRefusal(forClosing workspaces: [Workspace]) -> UnsavedChangesCloseRefusal? {
        var candidates = workspaces.flatMap(\.closablePanelsIncludingDock)
        let closingIds = Set(workspaces.map(\.id))
        let closesWholeWindow = !tabs.isEmpty && tabs.allSatisfy { closingIds.contains($0.id) }
        if closesWholeWindow,
           let windowDock = AppDelegate.shared?.mainWindowContext(for: self)?.existingWindowDock() {
            candidates += Array(windowDock.panels.values)
        }
        return unsavedChangesCloseConfirmation.refusal(forClosing: candidates)
    }
}
