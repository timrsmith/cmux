public import Foundation

/// The result of a non-interactive window close request.
public enum ControlWindowCloseResolution: Sendable, Equatable {
    case resolved
    case confirmationRequired(workspaceIDs: [UUID])
    /// The window holds unsaved edits and `force` was not passed.
    case unsavedChanges(ControlUnsavedChangesRefusal)
    case notFound
}
