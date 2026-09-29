import AppKit

/// The "Go to Line" popover anchored to a file editor: one field that takes
/// `line` or `line:column`, commits on Return, and closes on Escape.
@MainActor
final class FilePreviewGoToLinePopover: NSObject, NSTextFieldDelegate, NSPopoverDelegate {
    private let popover = NSPopover()
    private let field = NSTextField()
    private let onCommit: (FilePreviewLineLocator.Target) -> Void
    private var onClose: (() -> Void)?

    init(currentLine: Int, onCommit: @escaping (FilePreviewLineLocator.Target) -> Void) {
        self.onCommit = onCommit
        super.init()
        let controller = NSViewController()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 40))
        field.frame = NSRect(x: 10, y: 8, width: 200, height: 24)
        field.placeholderString = String(
            localized: "fileEditor.goToLine.placeholder",
            defaultValue: "Line or line:column"
        )
        field.stringValue = String(currentLine)
        field.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.delegate = self
        field.setAccessibilityLabel(KeyboardShortcutSettings.Action.goToLine.label)
        content.addSubview(field)
        controller.view = content
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown }

    /// Shows the popover below `rect` in `view` and focuses the field.
    func show(relativeTo rect: NSRect, of view: NSView, onClose: @escaping () -> Void) {
        self.onClose = onClose
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        field.selectText(nil)
    }

    /// Commits `text` as if Return were pressed; false when it does not parse.
    @discardableResult
    func commit(_ text: String) -> Bool {
        guard let target = FilePreviewLineLocator.parse(text) else {
            NSSound.beep()
            return false
        }
        popover.performClose(nil)
        onCommit(target)
        return true
    }

    // MARK: NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commit(field.stringValue)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            popover.performClose(nil)
            return true
        }
        return false
    }

    // MARK: NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        let handler = onClose
        onClose = nil
        handler?()
    }
}
