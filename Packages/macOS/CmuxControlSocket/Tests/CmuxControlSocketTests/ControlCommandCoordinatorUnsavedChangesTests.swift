import Foundation
import Testing
@testable import CmuxControlSocket

/// The close commands forward `force` to the app and turn an unsaved-changes
/// refusal into the stable `unsaved_changes` error naming the files.
@MainActor
@Suite("ControlCommandCoordinator unsaved-changes refusals")
struct ControlCommandCoordinatorUnsavedChangesTests {
    private let refusal = ControlUnsavedChangesRefusal(
        fileNames: ["notes.md"],
        message: "“notes.md” has unsaved changes; save it first or pass --force."
    )

    @Test func surfaceCloseReportsTheRefusalAndForwardsForce() throws {
        let context = FakeSurfaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()
        let surfaceID = UUID()
        context.closeResolution = .unsavedChanges(surfaceID: surfaceID, refusal: refusal)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.close",
            params: [
                "workspace_id": .string(workspaceID.uuidString),
                "surface_id": .string(surfaceID.uuidString),
            ]
        ))

        guard case .err(let code, let message, .object(let data)) = result else {
            Issue.record("expected an unsaved_changes error, got \(result)")
            return
        }
        #expect(code == "unsaved_changes")
        #expect(message == refusal.message)
        #expect(data["files"] == .array([.string("notes.md")]))
        #expect(data["surface_id"] == .string(surfaceID.uuidString))
        #expect(context.closeForce == false)

        _ = coordinator.handle(ControlRequest(
            id: .int(2),
            method: "surface.close",
            params: [
                "workspace_id": .string(workspaceID.uuidString),
                "surface_id": .string(surfaceID.uuidString),
                "force": .bool(true),
            ]
        ))
        #expect(context.closeForce == true)
    }

    @Test func workspaceCloseReportsTheRefusalAndForwardsForce() throws {
        let context = FakeWorkspaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()
        let windowID = UUID()
        context.closeResolution = .unsavedChanges(windowID: windowID, refusal: refusal)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "workspace.close",
            params: ["workspace_id": .string(workspaceID.uuidString)]
        ))

        guard case .err(let code, let message, .object(let data)) = result else {
            Issue.record("expected an unsaved_changes error, got \(result)")
            return
        }
        #expect(code == "unsaved_changes")
        #expect(message == refusal.message)
        #expect(data["files"] == .array([.string("notes.md")]))
        #expect(data["workspace_id"] == .string(workspaceID.uuidString))
        #expect(data["window_id"] == .string(windowID.uuidString))
        #expect(context.closeForce == false)

        _ = coordinator.handle(ControlRequest(
            id: .int(2),
            method: "workspace.close",
            params: [
                "workspace_id": .string(workspaceID.uuidString),
                "force": .string("true"),
            ]
        ))
        #expect(context.closeForce == true)
    }

    @Test func windowCloseReportsTheRefusalAndForwardsForce() throws {
        let context = FakeWorkspaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let windowID = UUID()
        context.windowCloseResolution = .unsavedChanges(refusal)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "window.close",
            params: ["window_id": .string(windowID.uuidString)]
        ))

        guard case .err(let code, let message, .object(let data)) = result else {
            Issue.record("expected an unsaved_changes error, got \(result)")
            return
        }
        #expect(code == "unsaved_changes")
        #expect(message == refusal.message)
        #expect(data["files"] == .array([.string("notes.md")]))
        #expect(data["window_id"] == .string(windowID.uuidString))
        #expect(context.windowCloseForce == false)

        context.windowCloseResolution = .closed
        let forced = coordinator.handle(ControlRequest(
            id: .int(2),
            method: "window.close",
            params: ["window_id": .string(windowID.uuidString), "force": .bool(true)]
        ))
        #expect(context.windowCloseForce == true)
        guard case .ok = forced else {
            Issue.record("expected the forced close to succeed, got \(forced)")
            return
        }
    }

    @Test func tabActionBatchCloseReportsTheRefusal() throws {
        let context = FakeTabActionControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        context.resolution = .unsavedChanges(refusal)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "tab.action",
            params: ["action": .string("close_others"), "surface_id": .string(UUID().uuidString)]
        ))

        guard case .err(let code, let message, .object(let data)) = result else {
            Issue.record("expected an unsaved_changes error, got \(result)")
            return
        }
        #expect(code == "unsaved_changes")
        #expect(message == refusal.message)
        #expect(data["files"] == .array([.string("notes.md")]))
    }

    @Test func legacyCloseSurfaceReportsTheRefusal() {
        let context = FakeSidebarV1ControlCommandContext()
        context.closeSurfaceResolution = .unsavedChanges(refusal)
        let coordinator = ControlCommandCoordinator(context: context)

        let response = coordinator.handleSidebarV1(command: "close_surface", args: "")

        #expect(response == "ERROR: \(refusal.message)")
    }
}
