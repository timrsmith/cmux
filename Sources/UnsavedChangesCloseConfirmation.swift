import Foundation

/// One shared confirmation flow for closing panels that may hold unsaved edits.
///
/// Every close entry point (tab, pane, batch, workspace, window, quit) consults
/// this before the existing close-warning flow. It is not gated by the
/// `app.warnBeforeClosing*` settings: discarding edits is data loss, so a dirty
/// editor always asks.
///
/// Most close paths are synchronous while saving is asynchronous, so they use
/// ``deferCloseIfNeeded(for:retry:onCancel:)``: when something is dirty, the
/// caller returns immediately, the prompt (and any save) runs, and on Save or
/// Don't Save the very same close is re-issued through `retry` with the panels
/// marked resolved. The re-entered caller finds nothing left to ask about, sees
/// ``isCloseConfirmed(for:)`` and skips its own close warning: the unsaved
/// prompt replaces that confirmation for the action. When nothing is dirty the
/// existing warning flow runs unchanged.
@MainActor
final class UnsavedChangesCloseConfirmation {
    /// The result of one prompt-and-save round.
    enum Outcome: Equatable, Sendable {
        case proceed
        case cancel
    }

    private let presenter: any UnsavedChangesPromptPresenting
    /// Dirty panels whose discard the user accepted for the close being retried.
    private var resolvedPanelIds: Set<UUID> = []
    /// The prompt-and-retry currently running, if any. Tests await this.
    private(set) var inFlightResolution: Task<Void, Never>?

    init(presenter: any UnsavedChangesPromptPresenting) {
        self.presenter = presenter
    }

    /// Whether a prompt-and-retry is currently running.
    var isResolving: Bool { inFlightResolution != nil }

    /// The panels in `panels` holding unsaved edits that no pending retry has resolved.
    func unresolvedPanels(in panels: [any Panel]) -> [any UnsavedChangesTracking] {
        panels.compactMap { $0 as? any UnsavedChangesTracking }
            .filter { $0.hasUnsavedChanges && !resolvedPanelIds.contains($0.id) }
    }

    /// Whether `panels` belong to a close the user already answered through this
    /// prompt: the re-issued close after Save or Don't Save. That answer stands in
    /// for the close-warning confirmation (``UnsavedChangesClosePlan/confirmsClose(for:)``),
    /// so the caller skips its `CloseTabWarningStore` prompt for this action.
    func isCloseConfirmed(for panels: [any Panel]) -> Bool {
        isCloseConfirmed(forPanelIds: panels.map(\.id))
    }

    /// Panel-id form of ``isCloseConfirmed(for:)``.
    func isCloseConfirmed(forPanelIds panelIds: [UUID]) -> Bool {
        panelIds.contains { resolvedPanelIds.contains($0) }
    }

    /// Asks once for every dirty panel in `panels` and saves when asked.
    ///
    /// - Returns: `.proceed` when nothing is dirty, when the user chose Don't
    ///   Save, or when every save landed; `.cancel` when the user cancelled or a
    ///   save failed (the failure is shown and nothing has been closed).
    func confirmClose(of panels: [any UnsavedChangesTracking]) async -> Outcome {
        let dirtyPanels = panels.filter(\.hasUnsavedChanges)
        let plan = UnsavedChangesClosePlan(fileNames: dirtyPanels.map(\.unsavedChangesDisplayName))
        guard let prompt = plan.prompt else { return .proceed }
        let response = presenter.presentUnsavedChangesPrompt(prompt)
        guard plan.confirmsClose(for: response) else { return .cancel }
        switch plan.outcome(for: response) {
        case .cancel:
            return .cancel
        case .proceed:
            return .proceed
        case .saveThenProceed:
            for panel in dirtyPanels {
                do {
                    try await panel.saveUnsavedChanges()
                } catch {
                    presenter.presentUnsavedChangesSaveFailure(error)
                    return .cancel
                }
            }
            return .proceed
        }
    }

    /// Gate for synchronous close paths.
    ///
    /// Returns `false` when nothing in `panels` needs asking, so the caller
    /// continues its own flow now. Returns `true` when it took the close over:
    /// the prompt runs, and on Save or Don't Save `retry` re-issues the same
    /// close with the dirty panels marked resolved; on Cancel or a failed save
    /// `onCancel` runs instead. A second request while a prompt is up is
    /// refused through `onCancel`.
    @discardableResult
    func deferCloseIfNeeded(
        for panels: [any Panel],
        retry: @escaping @MainActor () -> Void,
        onCancel: (@MainActor () -> Void)? = nil
    ) -> Bool {
        let unresolved = unresolvedPanels(in: panels)
        guard !unresolved.isEmpty else { return false }
        guard inFlightResolution == nil else {
            onCancel?()
            return true
        }
        inFlightResolution = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.confirmClose(of: unresolved)
            // Clear before retrying so the re-entered close sees no prompt in flight.
            self.inFlightResolution = nil
            guard outcome == .proceed else {
                onCancel?()
                return
            }
            let resolvedIds = unresolved.map(\.id)
            self.resolvedPanelIds.formUnion(resolvedIds)
            defer { self.resolvedPanelIds.subtract(resolvedIds) }
            retry()
        }
        return true
    }
}
