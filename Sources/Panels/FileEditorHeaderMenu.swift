import CmuxSettings
import CmuxSettingsUI
import SwiftUI

/// The "…" menu on a file editor tab's header: the editor's display
/// settings as live toggles (the same keys Settings > Files and Editing
/// edits, so the two never disagree), zoom, Go to Line, and the Settings
/// section itself.
struct FileEditorHeaderMenu: View {
    @ObservedObject var panel: FilePreviewPanel
    @LiveSetting(\.fileEditor.wordWrap) private var wordWrap
    @LiveSetting(\.fileEditor.lineNumbers) private var lineNumbers
    @LiveSetting(\.fileEditor.indentGuides) private var indentGuides
    @LiveSetting(\.fileEditor.currentLineHighlight) private var currentLineHighlight
    @LiveSetting(\.fileEditor.syntaxHighlighting) private var syntaxHighlighting
    @LiveSetting(\.fileEditor.tabWidth) private var tabWidth

    var body: some View {
        let tabWidthTitle = String(localized: "fileEditor.menu.tabWidth", defaultValue: "Tab Width")
        Menu {
            Toggle(String(localized: "fileEditor.menu.wordWrap", defaultValue: "Word Wrap"), isOn: $wordWrap)
            Toggle(String(localized: "fileEditor.menu.lineNumbers", defaultValue: "Line Numbers"), isOn: $lineNumbers)
            Toggle(String(localized: "fileEditor.menu.indentGuides", defaultValue: "Indent Guides"), isOn: $indentGuides)
            Toggle(
                String(localized: "fileEditor.menu.currentLineHighlight", defaultValue: "Highlight Current Line"),
                isOn: $currentLineHighlight
            )
            Toggle(
                String(localized: "fileEditor.menu.syntaxHighlighting", defaultValue: "Syntax Highlighting"),
                isOn: $syntaxHighlighting
            )
            Menu(tabWidthTitle) {
                Picker(tabWidthTitle, selection: $tabWidth) {
                    ForEach(Array(FileEditorCatalogSection.supportedTabWidthRange), id: \.self) { width in
                        Text(String(width)).tag(width)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Divider()
            Button(String(localized: "fileEditor.menu.zoomIn", defaultValue: "Zoom In")) {
                _ = panel.zoomTextPreviewIn()
            }
            Button(String(localized: "fileEditor.menu.zoomOut", defaultValue: "Zoom Out")) {
                _ = panel.zoomTextPreviewOut()
            }
            Button(String(localized: "fileEditor.menu.actualSize", defaultValue: "Actual Size")) {
                _ = panel.resetTextPreviewZoom()
            }
            Divider()
            Button(String(localized: "fileEditor.menu.goToLine", defaultValue: "Go to Line…")) {
                _ = (panel.textView as? SavingTextView)?.presentFilePreviewGoToLine()
            }
            Divider()
            Button(String(localized: "filesPanel.header.openSettings", defaultValue: "Files and Editing Settings…")) {
                SettingsWindowPresenter.show(navigationTarget: .filesAndEditing)
            }
        } label: {
            PanelHeaderIconGlyph(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "fileEditor.menu.options.tooltip", defaultValue: "Editor options"))
        .accessibilityLabel(String(localized: "fileEditor.menu.options.tooltip", defaultValue: "Editor options"))
        .accessibilityIdentifier("FileEditor.optionsMenu")
    }
}
