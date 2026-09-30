import CmuxSettings
import Foundation

/// One shared confirmation flow for closing panels that may hold unsaved edits.
///
/// Every close entry point (tab, pane, batch, workspace, window, quit) consults
/// this before the existing close-warning flow. It is not gated by the
/// `app.warnBeforeClosing*` settings: discarding edits is data loss, so a dirty
/// editor always asks.
///
/// Most close paths are synchronous while saving is asynchronous, so they use
/// ``gate(for:retry:onCancel:)``: when something is dirty, the caller returns
/// immediately, the prompt (and any save) runs, and on Save or Don't Save the
/// very same close is re-issued through `retry` with the panels marked
/// resolved. The re-entered caller finds nothing left to ask about, sees
/// ``Gate/confirmed`` and skips its own close warning: the unsaved prompt
/// replaces that confirmation for the action. When nothing is dirty the
/// existing warning flow runs unchanged.
///
/// Resolution is tracked per instance, so every owner along one close path
/// (`TabManager`, its workspaces and their Docks) must share the instance it
/// was handed rather than creating its own.
@MainActor
final class UnsavedChangesCloseConfirmation {
    /// Where a synchronous close stands after consulting the gate.
    enum Gate: Equatable, Sendable {
        /// A dirty panel is being asked about. The caller returns now; the
        /// close is re-issued through `retry` (or `onCancel` runs instead).
        case deferred
        /// The user already answered Save or Don't Save for this close, so
        /// the caller skips its own close warning.
        case confirmed
        /// Nothing is dirty and nothing was answered; the caller's own
        /// warning flow runs unchanged.
        case clear
    }

    private let presenter: any UnsavedChangesPromptPresenting
    /// Dirty panels whose discard the user accepted for the close being retried.
    private var resolvedPanelIds: Set<UUID> = []
    /// The prompt-and-retry currently running, if any. Tests await this.
    private(set) var inFlightResolution: Task<Void, Never>?

    /// Uses the AppKit alert unless a test injects a recording presenter.
    init(presenter: (any UnsavedChangesPromptPresenting)? = nil) {
        self.presenter = presenter ?? UnsavedChangesAlertPresenter()
    }

    /// The panels in `panels` holding unsaved edits that no pending retry has resolved.
    func unresolvedPanels(in panels: [any Panel]) -> [any UnsavedChangesTracking] {
        panels.compactMap { panel in
            guard let tracking = panel as? any UnsavedChangesTracking,
                  tracking.isDirty,
                  !resolvedPanelIds.contains(tracking.id) else { return nil }
            return tracking
        }
    }

    /// Whether `panels` belong to a close the user already answered through this
    /// prompt: the re-issued close after Save or Don't Save. That answer stands in
    /// for the close-warning confirmation, so the caller skips its
    /// `CloseTabWarningStore` prompt for this action.
    func isCloseConfirmed(for panels: [any Panel]) -> Bool {
        guard !resolvedPanelIds.isEmpty else { return false }
        return panels.contains { resolvedPanelIds.contains($0.id) }
    }

    /// Single-panel form of ``isCloseConfirmed(for:)`` for per-tab loops.
    func isCloseConfirmed(forPanelId panelId: UUID) -> Bool {
        resolvedPanelIds.contains(panelId)
    }

    /// The close warnings the caller's own flow still owes for `panelIds`:
    /// none when this prompt already confirmed their close, otherwise
    /// `store`'s answer for the caller's confirmation state and source.
    func closeWarningKinds(
        forPanelIds panelIds: some Collection<UUID>,
        store: some CloseTabWarningReading,
        requiresConfirmation: Bool,
        source: CloseTabCloseSource
    ) -> CloseWarningKinds {
        if !resolvedPanelIds.isEmpty, panelIds.contains(where: { resolvedPanelIds.contains($0) }) {
            return []
        }
        return store.warningKinds(requiresConfirmation: requiresConfirmation, source: source)
    }

    /// Asks once for every dirty panel in `panels` and saves when asked. Clean
    /// panels in `panels` are ignored, so callers may pass candidates unfiltered.
    ///
    /// - Returns: `true` when the close may proceed: nothing was dirty, the user
    ///   chose Don't Save, or every save landed. `false` when the user cancelled
    ///   or a save failed (the failure is shown and nothing has been closed).
    func confirmClose(of panels: [any UnsavedChangesTracking]) async -> Bool {
        let dirtyPanels = panels.filter(\.isDirty)
        let plan = UnsavedChangesClosePlan(fileNames: dirtyPanels.map(\.unsavedChangesDisplayName))
        guard let prompt = plan.prompt else { return true }
        switch plan.outcome(for: presenter.presentUnsavedChangesPrompt(prompt)) {
        case .cancel:
            return false
        case .proceed:
            return true
        case .saveThenProceed:
            for panel in dirtyPanels {
                do {
                    try await panel.saveUnsavedChanges()
                } catch {
                    presenter.presentUnsavedChangesSaveFailure(error)
                    return false
                }
            }
            return true
        }
    }

    /// Gate for synchronous close paths.
    ///
    /// Returns ``Gate/deferred`` when it took the close over: the prompt runs,
    /// and on Save or Don't Save `retry` re-issues the same close with the dirty
    /// panels marked resolved; on Cancel or a failed save `onCancel` runs
    /// instead. A second request while a prompt is up is refused through
    /// `onCancel`. Otherwise the caller continues now, with ``Gate/confirmed``
    /// when this prompt already answered for `panels` and ``Gate/clear`` when
    /// nothing was dirty.
    func gate(
        for panels: [any Panel],
        retry: @escaping @MainActor () -> Void,
        onCancel: (@MainActor () -> Void)? = nil
    ) -> Gate {
        let unresolved = unresolvedPanels(in: panels)
        guard !unresolved.isEmpty else {
            return isCloseConfirmed(for: panels) ? .confirmed : .clear
        }
        guard inFlightResolution == nil else {
            onCancel?()
            return .deferred
        }
        inFlightResolution = Task { @MainActor [weak self] in
            guard let self else { return }
            let proceed = await self.confirmClose(of: unresolved)
            // Clear before retrying so the re-entered close sees no prompt in flight.
            self.inFlightResolution = nil
            guard proceed else {
                onCancel?()
                return
            }
            let resolvedIds = unresolved.map(\.id)
            self.resolvedPanelIds.formUnion(resolvedIds)
            defer { self.resolvedPanelIds.subtract(resolvedIds) }
            retry()
        }
        return .deferred
    }
}
