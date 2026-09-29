import AppKit

/// Routes each find command to the surface the panel is showing: the
/// rendered preview's in-page find, or the text editor's find bar in text
/// (source) mode. This is the only place that decision is made; callers such
/// as `TabManager` never inspect `displayMode`.
extension MarkdownPanel: FindablePanel {
    var isFindVisible: Bool {
        switch displayMode {
        case .preview: return searchState != nil
        case .text: return isTextFindVisible
        }
    }

    var canUseSelectionForFind: Bool {
        switch displayMode {
        case .preview: return false
        case .text: return textEditorHasSelectionForFind
        }
    }

    @discardableResult
    func startFind(replace: Bool) -> Bool {
        switch displayMode {
        case .preview:
            startPreviewFind()
            return searchState != nil
        case .text:
            return startTextFind(replace: replace)
        }
    }

    func findNext() {
        switch displayMode {
        case .preview: findNextInPreview()
        case .text: performTextFinderAction(.nextMatch)
        }
    }

    func findPrevious() {
        switch displayMode {
        case .preview: findPreviousInPreview()
        case .text: performTextFinderAction(.previousMatch)
        }
    }

    @discardableResult
    func useSelectionForFind() -> Bool {
        switch displayMode {
        case .preview: return false
        case .text: return performTextFinderAction(.setSearchString)
        }
    }

    func hideFind() {
        switch displayMode {
        case .preview: hidePreviewFind()
        case .text: performTextFinderAction(.hideFindInterface)
        }
    }
}
