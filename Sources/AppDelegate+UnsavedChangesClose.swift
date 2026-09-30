import AppKit

extension AppDelegate {
    /// Every panel that closes with `context`'s window: its workspaces, their
    /// Docks and the window Dock.
    func unsavedChangesCandidatePanels(in context: MainWindowContext) -> [any Panel] {
        context.tabManager.tabs.flatMap(\.closablePanelsIncludingDock)
            + (context.existingWindowDock().map { Array($0.panels.values) } ?? [])
    }

    /// Every panel the app would discard on quit, window Docks first. Mirrors
    /// `hasQuitConfirmationDirtyWorkspaces()`.
    func unsavedChangesCandidatePanelsForQuit() -> [any Panel] {
        existingWindowDocks.flatMap { Array($0.panels.values) }
            + quitCandidateTabManagers().flatMap { $0.tabs.flatMap(\.closablePanelsIncludingDock) }
    }

    /// Every workspace owner the app discards on quit, each once: the window
    /// managers, the primary manager and the windowless recoverable owners that
    /// UI routing hides but a lifecycle/data-safety check must include. Window
    /// Docks are not managers; callers count `existingWindowDocks` themselves.
    func quitCandidateTabManagers() -> [TabManager] {
        var visitedManagers = Set<ObjectIdentifier>()
        var managers: [TabManager] = []

        func collect(_ manager: TabManager?) {
            guard let manager,
                  visitedManagers.insert(ObjectIdentifier(manager)).inserted else { return }
            managers.append(manager)
        }

        for context in mainWindowContexts.values {
            collect(context.tabManager)
        }
        collect(tabManager)
        for route in mainWindowSessionPersistenceRoutes() {
            collect(route.tabManager)
        }
        return managers
    }
}
