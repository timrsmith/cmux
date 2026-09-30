import Foundation

extension MarkdownPanel: TabMetadataPublishingPanel {
    /// Returns one consistent snapshot of the panel's tab-facing state.
    var currentTabMetadata: FilePreviewTabMetadata {
        FilePreviewTabMetadata(
            title: displayTitle,
            displayIcon: displayIcon,
            isDirty: isDirty
        )
    }
}
