import Foundation

/// A panel that answers the app-level find family: Find, Find and Replace,
/// Find Next, Find Previous, Use Selection for Find, and Hide Find.
///
/// `TabManager` resolves one focused ``FindablePanel`` (selected terminal,
/// focused browser, focused text file preview, focused markdown panel, in that
/// order) and forwards each Edit > Find command to it. Panels own their own
/// find UI: a terminal uses the Ghostty search overlay, a browser its in-page
/// find (or the diff viewer app's), a text editor the `NSTextFinder` bar, and
/// a markdown panel picks between its rendered preview and its text editor
/// from its own display mode.
///
/// ```swift
/// extension BrowserPanel: FindablePanel {
///     var isFindVisible: Bool { searchState != nil }
///     // ...
/// }
/// ```
@MainActor
protocol FindablePanel: AnyObject {
    /// Whether this panel's find UI is currently showing.
    var isFindVisible: Bool { get }

    /// Whether the panel has a selection that Use Selection for Find could
    /// adopt as the search needle. Panels without a native selection source
    /// answer `false`.
    var canUseSelectionForFind: Bool { get }

    /// Shows or refocuses the panel's find UI.
    ///
    /// - Parameter replace: Asks a native text editor for its find-and-replace
    ///   bar; every other panel kind, and a read-only editor, shows its plain
    ///   find UI.
    /// - Returns: `true` when the panel handled the command, even when it owns
    ///   find without showing a native bar (a diff viewer page); `false` when
    ///   nothing could show (an editor not attached to a window).
    @discardableResult
    func startFind(replace: Bool) -> Bool

    /// Moves to the next match of the active search.
    func findNext()

    /// Moves to the previous match of the active search.
    func findPrevious()

    /// Adopts the panel's current selection as the search needle.
    ///
    /// - Returns: `true` when the panel acted on the request, `false` when it
    ///   has no selection source or no find UI to receive it.
    @discardableResult
    func useSelectionForFind() -> Bool

    /// Hides the panel's find UI, leaving the panel's own focus intact.
    func hideFind()
}
