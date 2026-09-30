import Foundation

extension SettingsSectionID {
    /// Scroll anchors that pointed at Devices before it became its own
    /// section: the old Computers pairing row, and the subsection it was
    /// nested as under Mobile. Persisted navigation targets and older
    /// callers still send them.
    static let legacyDevicesAnchorIDs: Set<String> = [
        "setting:computers:pair",
        "setting:mobile:computers"
    ]

    /// The anchors the settings that moved into Files and Editing had under
    /// App (the file editor rows, Open Files From Tree In, Terminal Editor)
    /// or Sidebar (Files Panel). Persisted navigation targets and older
    /// callers still send them. Row ids are unique across sections
    /// (``SettingsSearchIndex`` keys every row `setting:<section>:<rowId>`),
    /// so the redirect keeps the anchor's row id and swaps in the section.
    static let legacyFilesAndEditingAnchorIDs: Set<String> = [
        "setting:app:file-editor-word-wrap",
        "setting:app:file-editor-syntax-highlighting",
        "setting:app:file-editor-line-numbers",
        "setting:app:file-editor-indent-guides",
        "setting:app:file-editor-current-line-highlight",
        "setting:app:file-editor-tab-width",
        "setting:app:file-explorer-double-click-action",
        "setting:app:file-editor-terminal-editor-command",
        "setting:sidebarAppearance:files-panel-placement"
    ]

    /// The section a navigation request for this id selects, and the anchor
    /// the detail pane scrolls to.
    ///
    /// Sidebar selection and the detail scroll both resolve through here so
    /// they cannot disagree about where a request lands. A request without
    /// an anchor lands on the section header; a legacy Devices anchor lands
    /// on the Devices header whichever section it was posted for, and a
    /// legacy App or Sidebar anchor for a row that moved to Files and
    /// Editing lands on that row in its new section.
    func navigationDestination(providedAnchor: String?) -> (section: SettingsSectionID, anchorID: String) {
        if let providedAnchor, Self.legacyDevicesAnchorIDs.contains(providedAnchor) {
            return (.computers, "section:\(Self.computers.rawValue)")
        }
        if let providedAnchor, Self.legacyFilesAndEditingAnchorIDs.contains(providedAnchor),
           let rowID = providedAnchor.split(separator: ":").last {
            return (.filesAndEditing, "setting:\(Self.filesAndEditing.rawValue):\(rowID)")
        }
        return (self, providedAnchor ?? "section:\(rawValue)")
    }

    /// Decodes a `cmux.settings.navigate` notification's `target` and
    /// optional `anchor`, or returns `nil` for an unknown target.
    static func navigationDestination(
        userInfo: [AnyHashable: Any]?
    ) -> (section: SettingsSectionID, anchorID: String)? {
        guard
            let rawValue = userInfo?["target"] as? String,
            let requested = SettingsSectionID(rawValue: rawValue)
        else { return nil }
        return requested.navigationDestination(providedAnchor: userInfo?["anchor"] as? String)
    }
}
