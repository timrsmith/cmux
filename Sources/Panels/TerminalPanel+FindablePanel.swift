import CmuxTerminal
import Foundation

extension TerminalPanel: FindablePanel {
    var isFindVisible: Bool { searchState != nil }

    var canUseSelectionForFind: Bool { hasSelection() }

    /// Opens or refocuses the Ghostty search overlay. A fresh search recovers
    /// the surface's last needle and selects it so typing replaces it.
    /// `replace` is ignored: the terminal has no replace UI.
    @discardableResult
    func startFind(replace: Bool) -> Bool {
        let hadExistingSearch = searchState != nil
        hostedView.preparePanelFocusIntentForActivation(.findField)
        let recoveredNeedle = hadExistingSearch ? "" : surface.lastSearchNeedle
        let handled = startOrFocusTerminalSearch(surface, initialNeedle: recoveredNeedle) { surface in
            NotificationCenter.default.post(
                name: .ghosttySearchFocus,
                object: surface,
                userInfo: [FindFocusNotificationKey.selectAll: !hadExistingSearch && !recoveredNeedle.isEmpty]
            )
        }
#if DEBUG
        cmuxDebugLog(
            "find.startSearch workspace=\(workspaceId.uuidString.prefix(5)) " +
            "panel=\(id.uuidString.prefix(5)) existing=\(hadExistingSearch ? "yes" : "no") " +
            "handled=\(handled ? 1 : 0) " +
            "firstResponder=\(String(describing: surface.uiWindow?.firstResponder))"
        )
#endif
        return handled
    }

    func findNext() {
        _ = TerminalSearchNavigation.next.perform { performBindingAction($0) }
    }

    func findPrevious() {
        _ = TerminalSearchNavigation.previous.perform { performBindingAction($0) }
    }

    /// Opens the search overlay if needed, focuses it, and asks Ghostty to
    /// seed the needle from the terminal selection.
    @discardableResult
    func useSelectionForFind() -> Bool {
        if searchState == nil {
            searchState = TerminalSurface.SearchState()
        }
#if DEBUG
        cmuxDebugLog(
            "find.searchSelection workspace=\(workspaceId.uuidString.prefix(5)) " +
            "panel=\(id.uuidString.prefix(5))"
        )
#endif
        NotificationCenter.default.post(name: .ghosttySearchFocus, object: surface)
        _ = performBindingAction("search_selection")
        return true
    }

    func hideFind() {
        surface.closeSearchFromExplicitInput()
    }
}
