import Foundation

/// A panel that projects its title, icon and dirty state to the tab hosting it.
///
/// ``FilePreviewPanel`` and ``MarkdownPanel`` both adopt this so every text
/// editor reaches its Bonsplit tab through one synchronous seam: the container
/// (``Workspace`` or ``DockSplitStore``) binds itself as the
/// ``FilePreviewTabMetadataHost`` and the panel pushes one consolidated
/// snapshot whenever a tab-facing value changes.
@MainActor
protocol TabMetadataPublishingPanel: Panel {
    /// The one container currently projecting this panel's tab metadata.
    var tabMetadataHost: (any FilePreviewTabMetadataHost)? { get set }

    /// One consistent snapshot of the panel's tab-facing state.
    var currentTabMetadata: FilePreviewTabMetadata { get }
}

extension TabMetadataPublishingPanel {
    /// Replaces the current container binding and immediately projects current state.
    func bindTabMetadata(to host: any FilePreviewTabMetadataHost) {
        tabMetadataHost = host
        host.applyFilePreviewTabMetadata(currentTabMetadata, panelId: id)
    }

    /// Clears the current container binding during transfer or teardown.
    func unbindTabMetadata() {
        tabMetadataHost = nil
    }

    /// Projects the consolidated snapshot through the panel's single active host.
    func publishTabMetadataUpdate() {
        tabMetadataHost?.applyFilePreviewTabMetadata(currentTabMetadata, panelId: id)
    }
}
