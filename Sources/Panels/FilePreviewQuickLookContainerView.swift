import AppKit
import Quartz

/// Stable host that owns the full lifecycle of one replaceable Quick Look view.
///
/// Quick Look closes a preview automatically when its window closes unless the
/// application opts into explicit ownership. This host disables that implicit
/// close and retires the preview before a real window detachment or final
/// representable teardown, so no closed preview is reused.
final class FilePreviewQuickLookContainerView: NSView {
    private var previewView: QLPreviewView?
    private var isDismantled = false
    /// Set between the window-transition notice and the move itself. The
    /// preview is retired at the notice; a SwiftUI update that runs during
    /// the detachment (the window's first-responder change reaches the
    /// hosting view) must not create a replacement inside the departing
    /// window, which Quick Look aborts on when the item is set.
    private var isLeavingWindow = false

    /// Creates an empty stable host for a replaceable inner preview.
    static func make() -> FilePreviewQuickLookContainerView {
        FilePreviewQuickLookContainerView(frame: .zero)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let currentWindow = window, currentWindow !== newWindow {
            isLeavingWindow = true
            retireLivePreview(reason: "window-transition")
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isLeavingWindow = false
    }

    /// Returns the preview owned by this mounted host, creating it when needed.
    /// A dismantled representable cannot create or re-adopt a preview, and
    /// neither can one that is on its way out of a window.
    func livePreviewView() -> QLPreviewView? {
        if let previewView {
            return previewView
        }
        guard !isDismantled, !isLeavingWindow else { return nil }

        guard let previewView = QLPreviewView(frame: bounds, style: .normal) else {
            return nil
        }
        previewView.autostarts = true
        previewView.shouldCloseWithWindow = false
        previewView.autoresizingMask = [.width, .height]
        addSubview(previewView)
        self.previewView = previewView
        return previewView
    }

    /// Clears the active item while preserving a reusable live preview.
    func clearPreviewItem() {
        previewView?.previewItem = nil
    }

    /// Permanently tears down this representable's Quick Look ownership.
    func dismantle() {
        guard !isDismantled else { return }
        isDismantled = true
        retireLivePreview(reason: "representable-dismantle")
        removeFromSuperview()
    }

    private func retireLivePreview(reason: String) {
        guard let previewView else { return }
        sentryBreadcrumb(
            "quickLook.preview.retire",
            category: "filePreview",
            data: ["reason": reason]
        )
        // Unreachable before it is closed: removing a first-responder preview
        // resets the window's first responder, SwiftUI runs a pending update
        // from that change, and a closed preview must not be handed out to
        // it. Quick Look aborts on an item set on a closed preview.
        self.previewView = nil
        previewView.previewItem = nil
        // `shouldCloseWithWindow` transfers closure ownership to this host even
        // when the preview has never entered a window.
        previewView.close()
        previewView.removeFromSuperview()
    }
}
