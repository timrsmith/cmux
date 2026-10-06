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

    /// The one question every automation close asks before closing: which of
    /// `panels` would lose unsaved edits. A socket, CLI, mobile-companion or
    /// AppleScript close cannot answer the prompt, so it refuses with the
    /// returned reason instead of prompting; `nil` means the close may proceed.
    /// Clean panels are ignored, so callers pass candidates unfiltered. Pending
    /// retries do not count: a non-interactive close is never a re-issued one.
    func refusal(forClosing panels: [any Panel]) -> UnsavedChangesCloseRefusal? {
        let dirtyPanels = panels.compactMap { panel -> (any UnsavedChangesTracking)? in
            guard let tracking = panel as? any UnsavedChangesTracking, tracking.isDirty else { return nil }
            return tracking
        }
        guard !dirtyPanels.isEmpty else { return nil }
        return UnsavedChangesCloseRefusal(fileNames: dirtyPanels.map(\.unsavedChangesDisplayName))
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
        source: CloseTabCloseSource,
        isAgentSession: Bool = false,
        hasActiveProcess: Bool? = nil
    ) -> CloseWarningKinds {
        if !resolvedPanelIds.isEmpty, panelIds.contains(where: { resolvedPanelIds.contains($0) }) {
            return []
        }
        // An active process is never killed silently, whatever the warning
        // settings say (`.safety`). Callers whose `requiresConfirmation` is a
        // policy rather than a process check pass `hasActiveProcess` explicitly.
        // An agent mid-turn gets its own dialog instead, as the store does.
        var kinds = store.warningKinds(
            requiresConfirmation: requiresConfirmation,
            source: source,
            isAgentSession: isAgentSession
        )
        if (hasActiveProcess ?? requiresConfirmation) && !isAgentSession {
            kinds.insert(.safety)
        }
        return kinds
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

/// Why a non-interactive close (socket, CLI, mobile companion, AppleScript)
/// was refused: the files whose edits it would have discarded. Automation
/// cannot answer the Save / Don't Save / Cancel prompt, so it is told which
/// files to save first; a close carrying an explicit force flag skips this.
struct UnsavedChangesCloseRefusal: Error, Equatable, Sendable {
    /// The stable socket error code; an identifier, never localized.
    static let socketErrorCode = "unsaved_changes"

    /// The dirty file names, in close order.
    let fileNames: [String]

    /// The reason for callers without a force flag (mobile companion, AppleScript).
    var message: String { Self.message(naming: fileNames, forceHint: false) }

    /// The reason for socket and CLI callers, which can pass `--force` to discard.
    var commandLineMessage: String { Self.message(naming: fileNames, forceHint: true) }

    private static func message(naming fileNames: [String], forceHint: Bool) -> String {
        if fileNames.count == 1, let name = fileNames.first {
            let format = forceHint
                ? String(
                    localized: "close.unsavedChanges.refused.force.one",
                    defaultValue: "“%@” has unsaved changes; save it first or pass --force."
                )
                : String(
                    localized: "close.unsavedChanges.refused.one",
                    defaultValue: "“%@” has unsaved changes; save it first."
                )
            return String(format: format, locale: .current, name)
        }
        let format = forceHint
            ? String(
                localized: "close.unsavedChanges.refused.force.other",
                defaultValue: "%@ have unsaved changes; save them first or pass --force."
            )
            : String(
                localized: "close.unsavedChanges.refused.other",
                defaultValue: "%@ have unsaved changes; save them first."
            )
        return String(format: format, locale: .current, fileNames.joined(separator: ", "))
    }
}

/// The result of a non-interactive close that refuses rather than discards.
enum NonInteractiveCloseOutcome: Equatable {
    /// The target closed.
    case closed
    /// The target could not be closed for a reason other than unsaved edits
    /// (it was gone, pinned, or teardown did not complete).
    case failed
    /// Nothing closed: a panel holds unsaved edits and the close was not forced.
    case refused(UnsavedChangesCloseRefusal)
}
