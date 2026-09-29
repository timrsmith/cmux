import Foundation

/// `findNext()`, `findPrevious()`, and `hideFind()` are the browser's own
/// find methods, declared with the panel; this extension adds the members
/// the protocol needs beyond them.
extension BrowserPanel: FindablePanel {
    var isFindVisible: Bool { searchState != nil }

    /// The browser has no native selection source for the find needle.
    var canUseSelectionForFind: Bool { false }

    /// Shows the in-page find bar, or hands the command to a diff viewer page
    /// that owns find in-page. `replace` is ignored: the browser has no
    /// replace UI.
    ///
    /// - Returns: `true` when the native bar showed or the diff viewer owns
    ///   find (the shortcut was handled without a native bar).
    @discardableResult
    func startFind(replace: Bool) -> Bool {
        startFind()
        return searchState != nil || isDiffViewerFindOwner
    }

    @discardableResult
    func useSelectionForFind() -> Bool { false }
}
