import AppKit

extension AppDelegate {
    /// Every panel that closes with `context`'s window: its workspaces, their
    /// Docks and the window Dock.
    func unsavedChangesCandidatePanels(in context: MainWindowContext) -> [any Panel] {
        context.tabManager.tabs.flatMap(\.closablePanelsIncludingDock)
            + (context.existingWindowDock().map { Array($0.panels.values) } ?? [])
    }

    /// Every panel the app would discard on quit. Mirrors
    /// `hasQuitConfirmationDirtyWorkspaces()`, including windowless recoverable
    /// owners that UI routing hides.
    func unsavedChangesCandidatePanelsForQuit() -> [any Panel] {
        var visitedManagers = Set<ObjectIdentifier>()
        var panels: [any Panel] = existingWindowDocks.flatMap { Array($0.panels.values) }

        func collect(_ manager: TabManager?) {
            guard let manager,
                  visitedManagers.insert(ObjectIdentifier(manager)).inserted else { return }
            panels += manager.tabs.flatMap(\.closablePanelsIncludingDock)
        }

        for context in mainWindowContexts.values {
            collect(context.tabManager)
        }
        collect(tabManager)
        for route in mainWindowSessionPersistenceRoutes() {
            collect(route.tabManager)
        }
        return panels
    }
}
