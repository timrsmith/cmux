import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Every main window's `TabManager` and the app delegate's quit path share one
/// `UnsavedChangesCloseConfirmation`, so a Save / Don't Save / Cancel answer
/// given to a window close is the same gate quit consults. Extra windows get
/// the delegate's instance from `AppDelegate.createMainWindow`; the primary
/// manager built in `cmuxApp.init` receives it the same way. That manager is
/// the WindowGroup's bootstrap owner and is retired into a private
/// `@StateObject` once the first real window activates, so it cannot be
/// reached from here; this guards the managers the delegate does expose.
@Suite struct PrimaryTabManagerCloseConfirmationTests {
    @MainActor
    @Test func everyRegisteredMainWindowManagerSharesTheAppDelegatesConfirmation() throws {
        let appDelegate = try #require(
            AppDelegate.shared,
            "the unit-test host is the app, whose delegate owns the shared confirmation"
        )
        let active = try #require(appDelegate.tabManager, "the delegate tracks the active main window's manager")
        #expect(active.unsavedChangesCloseConfirmation === appDelegate.unsavedChangesCloseConfirmation)
        for context in appDelegate.mainWindowContexts.values {
            #expect(
                context.tabManager.unsavedChangesCloseConfirmation === appDelegate.unsavedChangesCloseConfirmation,
                "window \(context.windowId)"
            )
        }
    }
}
