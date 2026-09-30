import Foundation

/// The tab-facing state emitted by a text-editing panel.
///
/// Both ``FilePreviewPanel`` and ``MarkdownPanel`` project this snapshot to
/// their ``FilePreviewTabMetadataHost`` through ``TabMetadataPublishingPanel``.
struct FilePreviewTabMetadata: Equatable, Sendable {
    /// The resolved tab title.
    let title: String
    /// The optional system-symbol name shown in the tab.
    let displayIcon: String?
    /// Whether the editor has unsaved edits.
    let isDirty: Bool
}
