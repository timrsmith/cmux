import AppKit

extension ContentView {
    /// Clamps the right sidebar to its available and configured width caps.
    ///
    /// The content minimum can exceed either cap in a narrow window, so it is
    /// bounded by the effective maximum before it becomes the lower bound.
    static func clampedRightSidebarWidth(
        _ candidate: CGFloat,
        availableWidth: CGFloat,
        configuredMaximumWidth: CGFloat? = nil,
        contentMinimumWidth: CGFloat = 0
    ) -> CGFloat {
        let sanitizedCandidate = candidate.isFinite ? candidate : 220
        // No room left (the other panels fill the window) is an answer, the
        // floor; only an unmeasured width falls back to a screen-sized cap.
        let sanitizedAvailableWidth = availableWidth.isFinite ? max(0, availableWidth) : 1920
        let availableWidthCap = max(
            minimumRightSidebarWidth,
            sanitizedAvailableWidth - minimumTerminalWidthWithRightSidebar
        )
        let configuredOrDefaultCap: CGFloat
        if let configuredMaximumWidth, configuredMaximumWidth.isFinite {
            configuredOrDefaultCap = configuredMaximumWidth
        } else {
            configuredOrDefaultCap = maximumRightSidebarWidth
        }
        let maximumWidth = max(
            minimumRightSidebarWidth,
            min(configuredOrDefaultCap, availableWidthCap)
        )
        let contentMinimum = contentMinimumWidth.isFinite ? contentMinimumWidth : minimumRightSidebarWidth
        let minimumWidth = min(
            max(minimumRightSidebarWidth, contentMinimum),
            maximumWidth
        )
        return max(minimumWidth, min(maximumWidth, sanitizedCandidate))
    }
}
