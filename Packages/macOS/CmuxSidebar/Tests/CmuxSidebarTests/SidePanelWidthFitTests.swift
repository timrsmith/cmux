import CoreGraphics
import Testing
@testable import CmuxSidebar

@Suite("SidePanelWidthFit")
struct SidePanelWidthFitTests {
    private let left: CGFloat = 240
    private let right: CGFloat = 276
    private let floor = SidePanelWidthFit.minimumTerminalWidth

    private func terminalWidth(_ fit: SidePanelWidthFit, window: CGFloat) -> CGFloat {
        window - (fit.isLeftVisible ? left : 0) - (fit.isRightVisible ? right : 0)
    }

    /// The fuzzer's repro for #15346: a fresh window with both panels resized to 320 pt
    /// left the terminal area 0 pt wide.
    @Test func narrowWindowCollapsesBothPanelsAndKeepsTheTerminal() {
        let both = SidePanelWidthFit(isLeftVisible: true, isRightVisible: true)
        let fit = both.fitting(windowWidth: 320, leftWidth: left, rightWidth: right)
        #expect(!fit.isLeftVisible && !fit.isRightVisible)
        #expect(fit.isLeftAutoCollapsed && fit.isRightAutoCollapsed)
        #expect(terminalWidth(fit, window: 320) >= floor)
    }

    @Test func rightPanelCollapsesBeforeTheLeftOne() {
        let both = SidePanelWidthFit(isLeftVisible: true, isRightVisible: true)
        let fit = both.fitting(windowWidth: 600, leftWidth: left, rightWidth: right)
        #expect(fit.isLeftVisible)
        #expect(!fit.isRightVisible && fit.isRightAutoCollapsed)
        #expect(terminalWidth(fit, window: 600) >= floor)
    }

    @Test func fittingPanelsStayUntouched() {
        let both = SidePanelWidthFit(isLeftVisible: true, isRightVisible: true)
        #expect(both.fitting(windowWidth: left + right + floor, leftWidth: left, rightWidth: right) == both)
        #expect(both.fitting(windowWidth: 1440, leftWidth: left, rightWidth: right) == both)
    }

    @Test func autoCollapsedPanelsComeBackWhenTheWindowWidens() {
        let both = SidePanelWidthFit(isLeftVisible: true, isRightVisible: true)
        let narrow = both.fitting(windowWidth: 320, leftWidth: left, rightWidth: right)
        let middle = narrow.fitting(windowWidth: 600, leftWidth: left, rightWidth: right)
        #expect(middle.isLeftVisible && !middle.isRightVisible && middle.isRightAutoCollapsed)
        let wide = middle.fitting(windowWidth: 1440, leftWidth: left, rightWidth: right)
        #expect(wide == both)
    }

    @Test func personHiddenPanelsStayHidden() {
        let hidden = SidePanelWidthFit(isLeftVisible: false, isRightVisible: false)
        #expect(hidden.fitting(windowWidth: 1440, leftWidth: left, rightWidth: right) == hidden)
    }

    /// Every window width gives one answer however it was reached, so a live resize
    /// never flickers a panel at its threshold.
    @Test func decisionsDoNotFlipAtAnyWidth() {
        var fit = SidePanelWidthFit(isLeftVisible: true, isRightVisible: true)
        let widths = Array(stride(from: CGFloat(300), through: 1000, by: 1))
        for width in widths.reversed() + widths {
            fit = fit.fitting(windowWidth: width, leftWidth: left, rightWidth: right)
            #expect(fit.fitting(windowWidth: width, leftWidth: left, rightWidth: right) == fit)
            #expect(terminalWidth(fit, window: width) >= floor)
        }
        #expect(fit == SidePanelWidthFit(isLeftVisible: true, isRightVisible: true))
    }

    @Test func showingAPanelCollapsesTheOtherWhenBothDoNotFit() {
        let leftOnly = SidePanelWidthFit(isLeftVisible: true, isRightVisible: false)
        let fit = leftOnly.showing(.right, windowWidth: 600, leftWidth: left, rightWidth: right)
        #expect(fit.isRightVisible && !fit.isRightAutoCollapsed)
        #expect(!fit.isLeftVisible && fit.isLeftAutoCollapsed)
        #expect(fit.preferredPanel == .right)
    }

    /// Showing the right sidebar beside the left one in a mid-width window must
    /// survive the fit pass that follows (the left sidebar hiding, or any resize).
    @Test(arguments: [SidePanelWidthFit.Panel.left, .right])
    func aShownPanelSurvivesTheNextFit(panel: SidePanelWidthFit.Panel) {
        let start = panel == .left
            ? SidePanelWidthFit(isLeftVisible: false, isRightVisible: true, preferredPanel: .right)
            : SidePanelWidthFit(isLeftVisible: true, isRightVisible: false)
        for width in stride(from: CGFloat(300), through: 1200, by: 5) {
            let shown = start.showing(panel, windowWidth: width, leftWidth: left, rightWidth: right)
            let refit = shown.fitting(windowWidth: width, leftWidth: left, rightWidth: right)
            if width - (panel == .left ? left : right) >= floor {
                #expect(refit == shown, "width \(width)")
            }
            #expect(panel == .left ? shown.isLeftVisible : shown.isRightVisible)
        }
    }

    @Test func showingAPanelThatFitsKeepsTheOther() {
        let leftOnly = SidePanelWidthFit(isLeftVisible: true, isRightVisible: false)
        let fit = leftOnly.showing(.right, windowWidth: 1440, leftWidth: left, rightWidth: right)
        #expect(fit == SidePanelWidthFit(isLeftVisible: true, isRightVisible: true, preferredPanel: .right))
    }

    @Test func showingAnAutoCollapsedPanelClearsItsFlag() {
        let collapsed = SidePanelWidthFit(isLeftVisible: false, isRightVisible: false, isLeftAutoCollapsed: true)
        let fit = collapsed.showing(.left, windowWidth: 320, leftWidth: left, rightWidth: right)
        #expect(fit.isLeftVisible && !fit.isLeftAutoCollapsed)
    }

    /// A leading files panel (`sidebar.filesPanelPlacement` = `leading`) is a
    /// third panel this policy never collapses, so its width comes off the
    /// window before the sidebars are fit: 240 + 260 + 276 in a 900 pt window
    /// leaves 124 pt, under the terminal floor, so the right sidebar collapses
    /// although both sidebars alone would fit.
    @Test func aDockedFilesPanelCountsAgainstTheTerminal() {
        let both = SidePanelWidthFit(isLeftVisible: true, isRightVisible: true)
        let filesPanel: CGFloat = 260
        #expect(both.fitting(windowWidth: 900, leftWidth: left, rightWidth: right) == both)

        let fit = both.fitting(windowWidth: 900, leftWidth: left, rightWidth: right, dockedPanelsWidth: filesPanel)
        #expect(fit.isLeftVisible)
        #expect(!fit.isRightVisible && fit.isRightAutoCollapsed)
        #expect(terminalWidth(fit, window: 900) - filesPanel >= floor)

        // Showing the right sidebar beside the panel collapses the left one the same way.
        let shown = SidePanelWidthFit(isLeftVisible: true, isRightVisible: false)
            .showing(.right, windowWidth: 900, leftWidth: left, rightWidth: right, dockedPanelsWidth: filesPanel)
        #expect(shown.isRightVisible && !shown.isLeftVisible && shown.isLeftAutoCollapsed)

        // Room for all three: nothing collapses, and a collapsed sidebar returns.
        #expect(both.fitting(windowWidth: 1440, leftWidth: left, rightWidth: right, dockedPanelsWidth: filesPanel) == both)
        #expect(fit.fitting(windowWidth: 1440, leftWidth: left, rightWidth: right, dockedPanelsWidth: filesPanel) == both)
    }

    @Test func unknownWindowWidthChangesNothing() {
        let both = SidePanelWidthFit(isLeftVisible: true, isRightVisible: true)
        #expect(both.fitting(windowWidth: 0, leftWidth: left, rightWidth: right) == both)
        #expect(both.fitting(windowWidth: .nan, leftWidth: left, rightWidth: right) == both)
    }
}

extension SidePanelWidthFitTests {
    @Test(arguments: [CGFloat(120), 240, 260, 400])
    func fittingIsIdempotentForAnyLeftWidth(leftWidth: CGFloat) {
        let states = [
            SidePanelWidthFit(isLeftVisible: true, isRightVisible: true),
            SidePanelWidthFit(isLeftVisible: false, isRightVisible: true, isLeftAutoCollapsed: true),
            SidePanelWidthFit(isLeftVisible: true, isRightVisible: false, isRightAutoCollapsed: true),
            SidePanelWidthFit(isLeftVisible: false, isRightVisible: false,
                              isLeftAutoCollapsed: true, isRightAutoCollapsed: true),
        ]
        for state in states {
            for width in stride(from: CGFloat(300), through: 1200, by: 7) {
                let once = state.fitting(windowWidth: width, leftWidth: leftWidth, rightWidth: 276)
                #expect(once.fitting(windowWidth: width, leftWidth: leftWidth, rightWidth: 276) == once)
                #expect(once.isLeftVisible || once.isLeftAutoCollapsed)
                #expect(once.isRightVisible || once.isRightAutoCollapsed)
            }
        }
    }
}
