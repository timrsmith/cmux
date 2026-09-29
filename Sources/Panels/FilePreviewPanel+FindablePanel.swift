import AppKit

/// The file preview finds through its native text editor. Image, PDF, and
/// Quick Look previews have no attached text view, so every member answers
/// `false` or does nothing for them.
extension FilePreviewPanel: FindablePanel {
    var isFindVisible: Bool { isTextFindVisible }

    var canUseSelectionForFind: Bool { textEditorHasSelectionForFind }

    @discardableResult
    func startFind(replace: Bool) -> Bool {
        startTextFind(replace: replace)
    }

    func findNext() {
        performTextFinderAction(.nextMatch)
    }

    func findPrevious() {
        performTextFinderAction(.previousMatch)
    }

    @discardableResult
    func useSelectionForFind() -> Bool {
        performTextFinderAction(.setSearchString)
    }

    func hideFind() {
        performTextFinderAction(.hideFindInterface)
    }
}
