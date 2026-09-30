import CmuxSettings
import SwiftUI

/// **Files and Editing** section: where the file tree lives, where files
/// activated in it open, and how the built-in file editor displays text.
///
/// Two cards. The first holds the Files panel rows: Files Panel
/// (`sidebar.filesPanelPlacement`), Open Files From Tree In
/// (`fileExplorer.doubleClickAction`) and Terminal Editor
/// (`fileEditor.terminalEditorCommand`). The second holds the file editor's
/// display rows (`fileEditor.wordWrap`, `syntaxHighlighting`, `lineNumbers`,
/// `indentGuides`, `currentLineHighlight`, `tabWidth`). Open Files With
/// (`app.preferredEditor`) stays in App because the terminal Cmd-click path
/// owns it. The Files header's "…" menu edits the placement through the same
/// live setting and links here for the rest.
@MainActor
public struct FilesAndEditingSection: View {
    @State private var filesPanelPlacement: DefaultsValueModel<FilesPanelPlacement>
    @State private var doubleClickAction: DefaultsValueModel<FileExplorerDoubleClickAction>
    @State private var terminalEditorCommand: DefaultsValueModel<String>
    @State private var wordWrap: DefaultsValueModel<Bool>
    @State private var syntaxHighlighting: DefaultsValueModel<Bool>
    @State private var lineNumbers: DefaultsValueModel<Bool>
    @State private var indentGuides: DefaultsValueModel<Bool>
    @State private var currentLineHighlight: DefaultsValueModel<Bool>
    @State private var tabWidth: DefaultsValueModel<Int>

    /// - Parameters:
    ///   - defaultsStore: The store every row reads and writes through.
    ///   - catalog: The catalog that names the keys the rows bind to.
    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _filesPanelPlacement = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.sidebar.filesPanelPlacement))
        _doubleClickAction = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.fileExplorer.doubleClickAction))
        _terminalEditorCommand = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.fileEditor.terminalEditorCommand))
        _wordWrap = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.fileEditor.wordWrap))
        _syntaxHighlighting = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.fileEditor.syntaxHighlighting))
        _lineNumbers = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.fileEditor.lineNumbers))
        _indentGuides = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.fileEditor.indentGuides))
        _currentLineHighlight = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.fileEditor.currentLineHighlight))
        _tabWidth = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.fileEditor.tabWidth))
    }

    /// The section header followed by its two cards, `filesPanelCard` and
    /// `fileEditorCard`. Every row's `DefaultsValueModel` starts observing its
    /// store when the section appears (`startSettingsObservation`) and stops
    /// when it goes away, so a section the window has not shown costs nothing.
    public var body: some View {
        Group {
            SettingsSectionHeader(
                String(localized: "settings.section.filesAndEditing", defaultValue: "Files and Editing"),
                section: .filesAndEditing
            )
            .accessibilityIdentifier("SettingsFilesAndEditingSection")
            filesPanelCard
            fileEditorCard
        }
        .task {
            startSettingsObservation([
                filesPanelPlacement,
                doubleClickAction,
                terminalEditorCommand,
                wordWrap,
                syntaxHighlighting,
                lineNumbers,
                indentGuides,
                currentLineHighlight,
                tabWidth
            ])
        }
    }

    /// Where the tree lives, where its files open, and the terminal editor
    /// that Terminal Editor runs.
    private var filesPanelCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("sidebar.filesPanelPlacement"),
                String(localized: "settings.sidebar.filesPanelPlacement", defaultValue: "Files Panel"),
                subtitle: String(localized: "settings.sidebar.filesPanelPlacement.subtitle", defaultValue: "Where the file tree lives. Find, Changes, and the other tools stay in the right sidebar.")
            ) {
                IconLabeledSegmentedPicker(
                    options: FilesPanelPlacement.allCases,
                    selection: Binding(
                        get: { filesPanelPlacement.current },
                        set: { filesPanelPlacement.set($0) }
                    ),
                    title: { $0.localizedTitle },
                    symbolName: { $0.symbolName }
                )
                .fixedSize()
                .accessibilityIdentifier("SettingsFilesPanelPlacementPicker")
            }
            SettingsCardDivider()

            // Open Files From Tree In (fileExplorer.doubleClickAction).
            SettingsCardRow(
                configurationReview: .json("fileExplorer.doubleClickAction"),
                String(localized: "settings.fileExplorer.doubleClickAction", defaultValue: "Open Files From Tree In"),
                subtitle: String(localized: "settings.fileExplorer.doubleClickAction.subtitle", defaultValue: "Where a file opens when activated in the file tree, the right sidebar, or a diff viewer. Terminal Editor runs the command below in a terminal in cmux.")
            ) {
                Picker("", selection: Binding(get: { doubleClickAction.current }, set: { doubleClickAction.set($0) })) {
                    ForEach(FileExplorerDoubleClickAction.allCases, id: \.self) { option in
                        Text(option.localizedTitle).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("SettingsFileExplorerDoubleClickActionPicker")
            }
            SettingsCardDivider()

            // Terminal Editor (fileEditor.terminalEditorCommand).
            SettingsCardRow(
                configurationReview: .json("fileEditor.terminalEditorCommand"),
                String(localized: "settings.fileEditor.terminalEditorCommand", defaultValue: "Terminal Editor"),
                subtitle: String(localized: "settings.fileEditor.terminalEditorCommand.subtitle", defaultValue: "Command run in a cmux terminal when Terminal Editor is chosen, followed by the file path. Leave empty to let your login shell use $VISUAL, then $EDITOR, then vi.")
            ) {
                TextField(
                    String(localized: "settings.fileEditor.terminalEditorCommand.placeholder", defaultValue: "$EDITOR"),
                    text: Binding(get: { terminalEditorCommand.current }, set: { terminalEditorCommand.set($0) })
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .accessibilityIdentifier("SettingsFileEditorTerminalEditorCommandField")
            }
        }
    }

    /// The built-in file editor's display options.
    private var fileEditorCard: some View {
        SettingsCard {
            toggleRow(
                path: "fileEditor.wordWrap",
                String(localized: "settings.app.fileEditorWordWrap", defaultValue: "File Editor Word Wrap"),
                subtitle: String(localized: "settings.app.fileEditorWordWrap.subtitle", defaultValue: "Wrap long lines at the editor's right edge instead of scrolling horizontally. Applies to the plain-text file editor."),
                model: wordWrap,
                accessibilityIdentifier: "SettingsFileEditorWordWrapToggle"
            )
            SettingsCardDivider()

            toggleRow(
                path: "fileEditor.syntaxHighlighting",
                String(localized: "settings.app.fileEditorSyntaxHighlighting", defaultValue: "File Editor Syntax Highlighting"),
                subtitle: String(localized: "settings.app.fileEditorSyntaxHighlighting.subtitle", defaultValue: "Color keywords, strings, and other tokens in the built-in file editor."),
                model: syntaxHighlighting,
                accessibilityIdentifier: "SettingsFileEditorSyntaxHighlightingToggle"
            )
            SettingsCardDivider()

            toggleRow(
                path: "fileEditor.lineNumbers",
                String(localized: "settings.app.fileEditorLineNumbers", defaultValue: "File Editor Line Numbers"),
                subtitle: String(localized: "settings.app.fileEditorLineNumbers.subtitle", defaultValue: "Show a line-number gutter beside the built-in file editor."),
                model: lineNumbers,
                accessibilityIdentifier: "SettingsFileEditorLineNumbersToggle"
            )
            SettingsCardDivider()

            toggleRow(
                path: "fileEditor.indentGuides",
                String(localized: "settings.app.fileEditorIndentGuides", defaultValue: "File Editor Indent Guides"),
                subtitle: String(localized: "settings.app.fileEditorIndentGuides.subtitle", defaultValue: "Draw vertical guides at indent columns in the built-in file editor."),
                model: indentGuides,
                accessibilityIdentifier: "SettingsFileEditorIndentGuidesToggle"
            )
            SettingsCardDivider()

            toggleRow(
                path: "fileEditor.currentLineHighlight",
                String(localized: "settings.app.fileEditorCurrentLineHighlight", defaultValue: "File Editor Current Line Highlight"),
                subtitle: String(localized: "settings.app.fileEditorCurrentLineHighlight.subtitle", defaultValue: "Highlight the line that contains the caret when nothing is selected."),
                model: currentLineHighlight,
                accessibilityIdentifier: "SettingsFileEditorCurrentLineHighlightToggle"
            )
            SettingsCardDivider()

            SettingsCardRow(
                configurationReview: .json("fileEditor.tabWidth"),
                String(localized: "settings.app.fileEditorTabWidth", defaultValue: "File Editor Tab Width"),
                subtitle: String(localized: "settings.app.fileEditorTabWidth.subtitle", defaultValue: "Columns per tab stop, used by indent guides.")
            ) {
                Stepper(
                    value: Binding(
                        get: { tabWidth.current },
                        set: { tabWidth.set($0) }
                    ),
                    in: FileEditorCatalogSection.supportedTabWidthRange
                ) {
                    Text("\(tabWidth.current)")
                        .monospacedDigit()
                }
                .accessibilityLabel(
                    String(localized: "settings.app.fileEditorTabWidth", defaultValue: "File Editor Tab Width")
                )
                .accessibilityIdentifier("SettingsFileEditorTabWidthStepper")
            }
        }
    }

    /// A row with one small toggle bound to `model`, the shape every file
    /// editor display option but Tab Width takes.
    private func toggleRow(
        path: String,
        _ title: String,
        subtitle: String,
        model: DefaultsValueModel<Bool>,
        accessibilityIdentifier: String
    ) -> some View {
        SettingsCardRow(configurationReview: .json(path), title, subtitle: subtitle) {
            Toggle("", isOn: Binding(get: { model.current }, set: { model.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}
