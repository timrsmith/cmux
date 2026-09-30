public import Foundation

/// The outcome of `surface.close`, preserving the legacy body's distinct failures
/// and the closed identity.
///
/// The coordinator signals `unavailable`; the app resolves the workspace and
/// surface, closes it without any interactive prompt (refusing with
/// ``unsavedChanges(surfaceID:refusal:)`` when edits would be lost and `force`
/// was not passed), and returns this.
public enum ControlSurfaceCloseResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not available").
    case tabManagerUnavailable
    /// No workspace resolved (legacy `not_found` / "Workspace not found").
    case workspaceNotFound
    /// No surface resolved and none focused (legacy `not_found` / "No focused
    /// surface").
    case noFocusedSurface
    /// A `surface_id` param was present but did not resolve to a UUID/ref. This
    /// must fail closed instead of falling back to the focused surface.
    case invalidSurfaceID
    /// The surface id did not exist (legacy `not_found` / "Surface not found",
    /// `data: {"surface_id": …}`). Carries the surface id.
    case surfaceNotFound(UUID)
    /// The workspace has only one surface left (legacy `invalid_state` / "Cannot
    /// close the last surface").
    case lastSurface
    /// The surface has a live foreground process and requires `force`.
    case confirmationRequired(UUID)
    /// The close call failed (legacy `internal_error` / "Failed to close surface",
    /// `data: {"surface_id": …}`). Carries the surface id.
    case closeFailed(UUID)
    /// The surface is an editor with unsaved edits and `force` was not passed;
    /// nothing was closed.
    case unsavedChanges(surfaceID: UUID, refusal: ControlUnsavedChangesRefusal)
    /// The surface was closed. Carries the echoed identity.
    case closed(windowID: UUID?, workspaceID: UUID, surfaceID: UUID)
}
