import AppKit
import CmuxBrowser

/// Hosts the Changes panel's docked diff viewer inside the right sidebar.
///
/// The web view is what takes keyboard focus when a review comment is typed;
/// this host is the right sidebar's keyboard focus endpoint for Changes mode,
/// so the window's focus coordinator can tell those keystrokes belong to the
/// sidebar, the same way the Feed and Dock hosts do.
final class RightSidebarChangesKeyboardFocusView: NSView {
    let webView: CmuxWebView

    init(webView: CmuxWebView) {
        self.webView = webView
        super.init(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        webView.frame = bounds
        addSubview(webView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }

    /// Whether `responder` is this host, its web view, or anything inside it.
    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool {
        if responder === self || responder === webView { return true }
        guard let view = responder as? NSView else { return false }
        return view.isDescendant(of: self)
    }

    /// Focuses the web view, which routes keys to the document the panel shows.
    func focusHostFromCoordinator() -> Bool {
        window?.makeFirstResponder(webView) == true
    }
}
