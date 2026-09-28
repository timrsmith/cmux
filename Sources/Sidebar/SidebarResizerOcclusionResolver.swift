import AppKit
import CmuxFoundation

@MainActor
final class SidebarResizerCursorReleaseScheduler {
    private let scheduler: MainActorDeferredActionScheduler

    init(clock: any Clock<Duration> = ContinuousClock()) {
        scheduler = MainActorDeferredActionScheduler(clock: clock)
    }

    func cancelPendingRelease() {
        scheduler.cancel()
    }

    func schedule(
        force: Bool,
        delay: Duration,
        release: @escaping @MainActor (Bool) -> Void
    ) {
        scheduler.schedule(after: delay, zeroDelayPolicy: .yieldOnce) {
            release(force)
        }
    }
}

@MainActor
struct SidebarResizerOcclusionResolver {
    var topmostMouseEventWindowNumber: (NSPoint) -> Int? = { screenPoint in
        let windowNumber = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        return windowNumber > 0 ? windowNumber : nil
    }

    /// Whether `point` is inside any sidebar divider's hit band: the workspace
    /// sidebar's, the right sidebar's, or the leading files panel's (which,
    /// like the workspace sidebar, is on the leading side of its divider).
    func dividerBandContains(
        point: NSPoint,
        contentBounds: NSRect,
        isLeftSidebarVisible: Bool,
        leftDividerX: CGFloat,
        isRightSidebarVisible: Bool,
        rightDividerX: CGFloat,
        isFilesPanelVisible: Bool = false,
        filesDividerX: CGFloat = 0
    ) -> Bool {
        guard point.y >= contentBounds.minY, point.y <= contentBounds.maxY else { return false }
        if isLeftSidebarVisible,
           SidebarResizeInteraction.Edge.leading.hitRange(dividerX: leftDividerX).contains(point.x) {
            return true
        }
        if isFilesPanelVisible,
           SidebarResizeInteraction.Edge.leading.hitRange(dividerX: filesDividerX).contains(point.x) {
            return true
        }
        return isRightSidebarVisible &&
            SidebarResizeInteraction.Edge.trailing.hitRange(dividerX: rightDividerX).contains(point.x)
    }

    func bandMayActivate(
        isDragging: Bool,
        isInDividerBand: Bool,
        screenPoint: NSPoint,
        observedWindowNumber: Int
    ) -> Bool {
        guard !isDragging else { return true }
        guard isInDividerBand else { return false }
        return topmostMouseEventWindowNumber(screenPoint) == observedWindowNumber
    }
}
