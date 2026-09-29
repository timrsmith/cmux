import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Fixtures shared by the file editor suites: an editor hosted the way the
/// panel hosts it, isolated shortcut settings, and key events shaped like
/// the ones AppKit hands `performKeyEquivalent`.

/// A file editor inside a scroll view inside an off-screen window. The
/// window is never ordered front; close it when the test is done.
@MainActor
struct WindowedFilePreviewEditor {
    let window: NSWindow
    let scrollView: NSScrollView
    let textView: SavingTextView

    func close() {
        window.close()
    }
}

/// Hosts `textView` (a fresh editor by default) in a scroll view and window.
@MainActor
func makeWindowedEditor(
    hosting textView: SavingTextView = SavingTextView.makeFilePreviewTextView()
) -> WindowedFilePreviewEditor {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    scrollView.documentView = textView
    let window = NSWindow(
        contentRect: scrollView.frame,
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = scrollView
    return WindowedFilePreviewEditor(window: window, scrollView: scrollView, textView: textView)
}

/// Runs `body` against the default shortcut bindings in an isolated
/// `cmux.json` store, restoring the previous store afterwards.
@MainActor
func withDefaultShortcutSettings(
    prefix: String = "cmux-file-preview-editor",
    _ body: () throws -> Void
) rethrows {
    let originalStore = KeyboardShortcutSettings.installIsolatedTestFileStore(prefix: prefix)
    KeyboardShortcutSettings.resetAll()
    defer {
        KeyboardShortcutSettings.resetAll()
        KeyboardShortcutSettings.settingsFileStore = originalStore
    }
    try body()
}

/// Runs `body` with `contents` as the live `cmux.json`, restoring the
/// previous store and removing the file afterwards.
@MainActor
func withShortcutSettingsFile(_ contents: String, _ body: () throws -> Void) throws {
    let originalStore = KeyboardShortcutSettings.settingsFileStore
    let settingsFileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("cmux-file-preview-editor-\(UUID().uuidString).json", isDirectory: false)
    try contents.write(to: settingsFileURL, atomically: true, encoding: .utf8)
    KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
        primaryPath: settingsFileURL.path,
        fallbackPath: nil,
        additionalFallbackPaths: [],
        startWatching: false
    )
    KeyboardShortcutSettings.resetAll()
    defer {
        KeyboardShortcutSettings.resetAll()
        KeyboardShortcutSettings.settingsFileStore = originalStore
        try? FileManager.default.removeItem(at: settingsFileURL)
    }
    try body()
}

/// A key-down for `key` (its `charactersIgnoringModifiers`) with `flags`;
/// `characters` overrides the typed text, as Option does on a real layout.
func editorKeyEvent(
    _ key: String,
    characters: String? = nil,
    flags: NSEvent.ModifierFlags = .command,
    code: UInt16
) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: flags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters ?? key,
        charactersIgnoringModifiers: key,
        isARepeat: false,
        keyCode: code
    ))
}
