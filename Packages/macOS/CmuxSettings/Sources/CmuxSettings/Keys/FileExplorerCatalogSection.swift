import Foundation

/// Settings under the dotted-id prefix `fileExplorer.*`.
///
/// Controls the file tree (the right sidebar's Files tab, or the leading or
/// stacked Files panel). The tree's placement is a sidebar setting
/// (``SidebarCatalogSection/filesPanelPlacement``); this section owns how the
/// tree opens files.
public struct FileExplorerCatalogSection: SettingCatalogSection {
    /// What activating a file in the tree opens; see ``FileExplorerDoubleClickAction``.
    ///
    /// The UserDefaults key predates the catalog and is kept so stored
    /// choices survive the move.
    public let doubleClickAction = DefaultsKey<FileExplorerDoubleClickAction>(
        id: "fileExplorer.doubleClickAction",
        defaultValue: .preview,
        userDefaultsKey: "fileExplorerDoubleClickAction"
    )

    /// Creates the file explorer settings section with its default keys.
    public init() {}
}
