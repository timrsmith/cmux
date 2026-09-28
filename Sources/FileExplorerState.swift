import AppKit
import CmuxSettings
import SwiftUI

// MARK: - State (visibility toggle)

final class FileExplorerState: ObservableObject {
    private static let modeKey = "rightSidebar.mode"
    private static let customSidebarNameKey = "rightSidebar.customSidebarName"
    private let defaults: UserDefaults
    static let filesPanelVisibleKey = "filesPanel.isVisible"
    static let filesPanelWidthKey = "filesPanel.width"

    @Published var isVisible: Bool {
        didSet { persistVisibility() }
    }
    /// Hidden because the window was too narrow (SidePanelWidthFit), not by the
    /// person. Persisted as visible, so a narrow window neither changes the
    /// default for new windows nor the next launch. Set it before `isVisible`.
    var isAutoCollapsed = false {
        didSet { persistVisibility() }
    }

    private func persistVisibility() {
        defaults.set(isVisible || isAutoCollapsed, forKey: "fileExplorer.isVisible")
    }
    @Published var width: CGFloat {
        didSet { defaults.set(Double(width), forKey: "fileExplorer.width") }
    }

    /// Whether the leading files panel (the file tree docked between the
    /// workspace sidebar and the panes) is shown. Only laid out while
    /// `sidebar.filesPanelPlacement` is `leading`; the value is kept across
    /// placement changes so switching back and forth restores the panel.
    /// Independent of `isVisible`, which is the right sidebar.
    @Published var filesPanelVisible: Bool {
        didSet { UserDefaults.standard.set(filesPanelVisible, forKey: Self.filesPanelVisibleKey) }
    }
    /// Persisted width of the leading files panel.
    @Published var filesPanelWidth: CGFloat {
        didSet { UserDefaults.standard.set(Double(filesPanelWidth), forKey: Self.filesPanelWidthKey) }
    }

    /// Proportion of sidebar height allocated to the tab list (0.0-1.0).
    /// The file explorer gets the remaining space below.
    @Published var dividerPosition: CGFloat {
        didSet { defaults.set(Double(dividerPosition), forKey: "fileExplorer.dividerPosition") }
    }

    /// Whether hidden files (dotfiles) are shown in the tree.
    @Published var showHiddenFiles: Bool {
        didSet { defaults.set(showHiddenFiles, forKey: "fileExplorer.showHidden") }
    }

    @Published private var storedMode: RightSidebarMode
    @Published private var storedCustomSidebarName: String?

    /// Whether the right sidebar (Files / Find / Dock / …) currently owns
    /// keyboard/input focus in this window. Driven by `MainWindowFocusController`
    /// from its exclusive focus `intent`. Used to make main-pane focus and
    /// right-sidebar (Dock) focus mutually exclusive — the main pane dims its
    /// focus ring when the sidebar owns focus, and vice versa. Runtime-only (not
    /// persisted).
    @Published var rightSidebarOwnsInputFocus: Bool = false

    /// The right-sidebar Cloud picker belongs to this window, even before it mounts.
    @MainActor lazy var cloudTeamPickerPresentation = CloudTeamPickerPresentation()

    /// Active mode for the right sidebar (file tree, search, sessions, or enabled beta modes).
    var mode: RightSidebarMode {
        get { storedMode }
        set { setMode(newValue) }
    }

    var customSidebarName: String? {
        storedCustomSidebarName
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isVisible = defaults.bool(forKey: "fileExplorer.isVisible")
        let storedWidth = defaults.double(forKey: "fileExplorer.width")
        self.width = storedWidth > 0 ? CGFloat(storedWidth) : 220
        // The docked file tree starts shown: a user who picks the leading
        // placement wants the tree next to the workspace list, and closing it
        // is the persisted exception.
        let storedFilesPanelVisible = defaults.object(forKey: Self.filesPanelVisibleKey)
        self.filesPanelVisible = storedFilesPanelVisible == nil ? true : defaults.bool(forKey: Self.filesPanelVisibleKey)
        let storedFilesPanelWidth = defaults.double(forKey: Self.filesPanelWidthKey)
        self.filesPanelWidth = storedFilesPanelWidth > 0
            ? CGFloat(storedFilesPanelWidth)
            : FilesPanelPlacementLayout.defaultWidth
        let storedPosition = defaults.double(forKey: "fileExplorer.dividerPosition")
        self.dividerPosition = storedPosition > 0 ? CGFloat(storedPosition) : 0.6
        let storedShowHidden = defaults.object(forKey: "fileExplorer.showHidden")
        self.showHiddenFiles = storedShowHidden == nil ? true : defaults.bool(forKey: "fileExplorer.showHidden")
        let customSidebarName = defaults.string(forKey: Self.customSidebarNameKey)?.nilIfEmpty
        self.storedCustomSidebarName = customSidebarName
        let storedMode = RightSidebarMode.from(cliArgument: defaults.string(forKey: Self.modeKey) ?? "") ?? .files
        self.storedMode = Self.visibleMode(storedMode, defaults: defaults)
        defaults.set(self.storedMode.rawValue, forKey: Self.modeKey)
    }

    /// Re-lands the sidebar on a tab the mode bar shows. Unlike an explicit
    /// `mode` set (which may reveal a user-hidden tab: CLI, palette,
    /// notification routing), restore and preference changes never resurrect a
    /// hidden tab.
    func refreshModeAvailability(defaults: UserDefaults? = nil) {
        let defaults = defaults ?? self.defaults
        setMode(Self.visibleMode(storedMode, defaults: defaults), defaults: defaults)
    }

    func selectCustomSidebar(name rawName: String, defaults: UserDefaults? = nil) {
        let defaults = defaults ?? self.defaults
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        storedCustomSidebarName = name
        defaults.set(name, forKey: Self.customSidebarNameKey)
    }

    /// The persisted right-sidebar custom-sidebar name, readable without an
    /// instance (mode availability checks run from static contexts).
    static func persistedCustomSidebarName(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: customSidebarNameKey)?.nilIfEmpty
    }

    /// Where the file tree lives (`sidebar.filesPanelPlacement`), read from the
    /// catalog key the same way the mode availability checks read their gates,
    /// so static callers (mode bar tabs, positional shortcut digits, focus
    /// routing) agree with the live Settings value.
    nonisolated static func filesPanelPlacement(defaults: UserDefaults = .standard) -> FilesPanelPlacement {
        UserDefaultsSettingsClient(defaults: defaults).value(for: SidebarCatalogSection().filesPanelPlacement)
    }

    /// Whether the file tree is docked as its own leading panel rather than
    /// being a right-sidebar tab.
    nonisolated static func filesPanelIsLeading(defaults: UserDefaults = .standard) -> Bool {
        filesPanelPlacement(defaults: defaults) == .leading
    }

    /// The one action path behind every "show Files" entry point (CLI
    /// `right-sidebar files`, the Ctrl+1 mode shortcut, the command palette,
    /// notification routing, `openRightSidebarToolPane` fallbacks). With the
    /// leading placement it reveals the docked files panel and leaves the right
    /// sidebar's visibility and mode alone; otherwise it shows the right sidebar
    /// on its Files tab, exactly the pre-panel behavior. Focus is the
    /// `MainWindowFocusController`'s job, which calls this before focusing the
    /// registered `.files` host.
    func showFiles(defaults: UserDefaults = .standard) {
        if Self.filesPanelIsLeading(defaults: defaults) {
            setFilesPanelVisible(true)
        } else {
            setVisible(true)
            setMode(.files, defaults: defaults)
        }
    }

    /// Hides the file tree wherever it lives: closes the leading panel, or
    /// hides the right sidebar when it is showing the Files tab (any other tab
    /// stays put, since it is not "Files" that is showing).
    func hideFiles(defaults: UserDefaults = .standard) {
        if Self.filesPanelIsLeading(defaults: defaults) {
            setFilesPanelVisible(false)
        } else if mode == .files {
            setVisible(false)
        }
    }

    /// Whether the file tree is currently on screen, wherever it lives.
    func filesAreShown(defaults: UserDefaults = .standard) -> Bool {
        if Self.filesPanelIsLeading(defaults: defaults) {
            return filesPanelVisible
        }
        return isVisible && mode == .files
    }

    /// Toggles the file tree through `showFiles`/`hideFiles`.
    func toggleFiles(defaults: UserDefaults = .standard) {
        if filesAreShown(defaults: defaults) {
            hideFiles(defaults: defaults)
        } else {
            showFiles(defaults: defaults)
        }
    }

    func setFilesPanelVisible(_ nextValue: Bool) {
        guard filesPanelVisible != nextValue else { return }
        withoutLayoutAnimations {
            filesPanelVisible = nextValue
        }
    }

    func toggle() {
        setVisible(!isVisible)
    }

    func setVisible(_ nextValue: Bool) {
        guard isVisible != nextValue else { return }
        withoutLayoutAnimations {
            isVisible = nextValue
        }
    }

    /// Runs `body` with SwiftUI transactions and AppKit/Core Animation implicit
    /// layout changes suppressed, so a panel snaps open or closed instead of
    /// animating out of step with the terminal portals.
    private func withoutLayoutAnimations(_ body: () -> Void) {
        NSAnimationContext.beginGrouping()
        CATransaction.begin()
        defer {
            CATransaction.commit()
            NSAnimationContext.endGrouping()
        }

        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.setDisableActions(true)

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }

    private func setMode(_ mode: RightSidebarMode, defaults: UserDefaults? = nil) {
        let defaults = defaults ?? self.defaults
        let nextMode = Self.availableMode(mode, defaults: defaults)
        guard storedMode != nextMode else {
            if defaults.string(forKey: Self.modeKey) != nextMode.rawValue {
                defaults.set(nextMode.rawValue, forKey: Self.modeKey)
            }
            return
        }
        storedMode = nextMode
        defaults.set(nextMode.rawValue, forKey: Self.modeKey)
    }

    /// The mode the right sidebar may actually land on. Feature-gated modes
    /// fall back like before; with the leading placement `.files` is no longer
    /// a right-sidebar tab at all, so it (and any fallback) lands on the first
    /// tab the mode bar shows instead.
    private static func availableMode(
        _ mode: RightSidebarMode,
        defaults: UserDefaults
    ) -> RightSidebarMode {
        let filesInRightSidebar = !filesPanelIsLeading(defaults: defaults)
        if mode.isAvailable(defaults: defaults), mode != .files || filesInRightSidebar {
            return mode
        }
        if filesInRightSidebar {
            return .files
        }
        return RightSidebarMode.visibleModes(defaults: defaults).first ?? .find
    }

    private static func visibleMode(
        _ mode: RightSidebarMode,
        defaults: UserDefaults
    ) -> RightSidebarMode {
        let candidate = availableMode(mode, defaults: defaults)
        // Custom sidebars are selectable content, not customizable mode-bar tabs.
        if candidate == .customSidebar { return candidate }
        let visible = RightSidebarMode.visibleModes(defaults: defaults)
        if visible.contains(candidate) { return candidate }
        return visible.first ?? candidate
    }
}
