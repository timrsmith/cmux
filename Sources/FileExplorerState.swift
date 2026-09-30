import AppKit
import CmuxSettings
import SwiftUI

// MARK: - State (visibility toggle)

final class FileExplorerState: ObservableObject {
    private static let modeKey = "rightSidebar.mode"
    private static let customSidebarNameKey = "rightSidebar.customSidebarName"
    static let filesPanelVisibleKey = "filesPanel.isVisible"
    static let filesPanelWidthKey = "filesPanel.width"
    static let filesPanelStackedHeightKey = "filesPanel.stackedHeight"

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
        UserDefaults.standard.set(isVisible || isAutoCollapsed, forKey: "fileExplorer.isVisible")
    }
    @Published var width: CGFloat {
        didSet { UserDefaults.standard.set(Double(width), forKey: "fileExplorer.width") }
    }

    /// Whether the detached files panel (the file tree docked between the
    /// workspace sidebar and the panes with `leading`, or stacked above the
    /// workspace list with `stacked`) is shown. Starts `true`: a docked or
    /// stacked tree is shown until the user closes it, and that close is the
    /// persisted exception (`filesPanel.isVisible`). Only laid out while
    /// `sidebar.filesPanelPlacement` is one of those; the flag is shared by
    /// both detached placements and kept across placement changes, so
    /// switching back and forth restores the panel. Independent of
    /// `isVisible`, which is the right sidebar.
    @Published var filesPanelVisible: Bool {
        didSet { UserDefaults.standard.set(filesPanelVisible, forKey: Self.filesPanelVisibleKey) }
    }
    /// Persisted width of the leading files panel.
    @Published var filesPanelWidth: CGFloat {
        didSet { UserDefaults.standard.set(Double(filesPanelWidth), forKey: Self.filesPanelWidthKey) }
    }
    /// Persisted height of the Files region stacked above the workspace list
    /// (`filesPanel.stackedHeight`). Clamped against the live sidebar height
    /// by `FilesPanelStackedLayout` when laid out.
    @Published var filesPanelStackedHeight: CGFloat {
        didSet { UserDefaults.standard.set(Double(filesPanelStackedHeight), forKey: Self.filesPanelStackedHeightKey) }
    }

    /// The workspace sidebar that hosts the stacked Files region, supplied by
    /// the window's composition site (`AppDelegate.createMainWindow`), which
    /// constructs both states. `showFiles` needs it with the `stacked`
    /// placement because the tree lives inside the sidebar, so revealing Files
    /// while the sidebar is hidden must show the sidebar too. Held weakly: the
    /// window owns the sidebar state, and the sidebar's visibility handler
    /// (installed by `ContentView`) captures the view that holds this object,
    /// so a strong reference would close a cycle whenever a window is torn
    /// down without `onDisappear`. `nil` for a host with no workspace sidebar
    /// (`RightSidebarToolPanel`), which is then assumed visible.
    private(set) weak var stackedSidebarState: SidebarState?

    /// Proportion of sidebar height allocated to the tab list (0.0-1.0).
    /// The file explorer gets the remaining space below.
    @Published var dividerPosition: CGFloat {
        didSet { UserDefaults.standard.set(Double(dividerPosition), forKey: "fileExplorer.dividerPosition") }
    }

    /// Whether hidden files (dotfiles) are shown in the tree.
    @Published var showHiddenFiles: Bool {
        didSet { UserDefaults.standard.set(showHiddenFiles, forKey: "fileExplorer.showHidden") }
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

    /// - Parameter sidebar: The workspace sidebar hosting the stacked Files
    ///   region, or `nil` for a host without one (see `stackedSidebarState`).
    init(sidebar: SidebarState?) {
        self.stackedSidebarState = sidebar
        let defaults = UserDefaults.standard
        self.isVisible = defaults.bool(forKey: "fileExplorer.isVisible")
        let storedWidth = defaults.double(forKey: "fileExplorer.width")
        self.width = storedWidth > 0 ? CGFloat(storedWidth) : 220
        // The detached file tree starts shown: a user who picks the leading
        // or stacked placement wants the tree there, and closing it is the
        // persisted exception (see `filesPanelVisible`).
        let storedFilesPanelVisible = defaults.object(forKey: Self.filesPanelVisibleKey)
        self.filesPanelVisible = storedFilesPanelVisible == nil ? true : defaults.bool(forKey: Self.filesPanelVisibleKey)
        let storedFilesPanelWidth = defaults.double(forKey: Self.filesPanelWidthKey)
        self.filesPanelWidth = storedFilesPanelWidth > 0
            ? CGFloat(storedFilesPanelWidth)
            : FilesPanelPlacementLayout.defaultWidth
        let storedFilesPanelStackedHeight = defaults.double(forKey: Self.filesPanelStackedHeightKey)
        self.filesPanelStackedHeight = storedFilesPanelStackedHeight > 0
            ? CGFloat(storedFilesPanelStackedHeight)
            : FilesPanelStackedLayout.defaultHeight
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
    func refreshModeAvailability(defaults: UserDefaults = .standard) {
        setMode(Self.visibleMode(storedMode, defaults: defaults), defaults: defaults)
    }

    func selectCustomSidebar(name rawName: String, defaults: UserDefaults = .standard) {
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

    /// Whether the file tree lives anywhere other than the right sidebar's
    /// Files tab (`leading` or `stacked`): the right sidebar then has no Files
    /// tab, and "show Files" targets the detached panel.
    nonisolated static func filesPanelIsDetached(defaults: UserDefaults = .standard) -> Bool {
        filesPanelPlacement(defaults: defaults).isDetachedFromRightSidebar
    }

    /// The one action path behind every "show Files" entry point (CLI
    /// `right-sidebar files`, the Ctrl+1 mode shortcut, the command palette,
    /// notification routing, `openRightSidebarToolPane` fallbacks). With the
    /// leading placement it reveals the docked files panel and leaves the right
    /// sidebar's visibility and mode alone; with the stacked placement it
    /// reveals the Files region and the workspace sidebar that hosts it;
    /// otherwise it shows the right sidebar on its Files tab, exactly the
    /// pre-panel behavior. Focus is the `MainWindowFocusController`'s job,
    /// which calls this before focusing the registered `.files` host.
    func showFiles(defaults: UserDefaults = .standard) {
        showFiles(placement: Self.filesPanelPlacement(defaults: defaults), defaults: defaults)
    }

    private func showFiles(placement: FilesPanelPlacement, defaults: UserDefaults) {
        switch placement {
        case .leading:
            setFilesPanelVisible(true)
        case .stacked:
            setFilesPanelVisible(true)
            stackedSidebarState?.setVisible(true)
        case .rightSidebar:
            setVisible(true)
            setMode(.files, defaults: defaults)
        }
    }

    /// Carries "Files is showing" across a placement change so the tree does
    /// not vanish when the user moves it. A tree that was on screen under
    /// `previous` is shown under `next`. One that was not is left to the flag
    /// of its new home: a detached tree the user closed earlier stays closed
    /// (`filesPanelVisible` is `false` only then, so a tree never closed
    /// appears in its new home even when the Files tab was not the one
    /// showing), and a right sidebar on another tab stays on it. When the
    /// tree leaves the right sidebar, a right sidebar that was showing only
    /// the Files tab closes, since the tab it showed no longer exists there.
    ///
    /// The right sidebar's stored mode is re-landed on a tab the bar still
    /// shows (`refreshModeAvailability`) last, and only here: the decisions
    /// above read `mode` as it was under `previous`, and a refresh that ran
    /// first (the mode bar's own `onChange` used to) turned a showing Files
    /// tab into Find before this could see it. Called from the window when
    /// `sidebar.filesPanelPlacement` changes, after the store holds `next`.
    func applyPlacementChange(
        from previous: FilesPanelPlacement,
        to next: FilesPanelPlacement,
        defaults: UserDefaults = .standard
    ) {
        guard previous != next else { return }
        let wasShown = filesAreShown(placement: previous)
        if previous == .rightSidebar, next.isDetachedFromRightSidebar, mode == .files {
            setVisible(false)
        }
        if wasShown {
            showFiles(placement: next, defaults: defaults)
        }
        refreshModeAvailability(defaults: defaults)
    }

    /// Hides the file tree wherever it lives: closes the leading panel or the
    /// stacked Files region (the workspace sidebar itself stays), or hides the
    /// right sidebar when it is showing the Files tab (any other tab stays
    /// put, since it is not "Files" that is showing).
    func hideFiles(defaults: UserDefaults = .standard) {
        if Self.filesPanelIsDetached(defaults: defaults) {
            setFilesPanelVisible(false)
        } else if mode == .files {
            setVisible(false)
        }
    }

    /// Whether the file tree is currently on screen, wherever it lives. A
    /// stacked Files region is on screen only while the workspace sidebar that
    /// hosts it is shown.
    func filesAreShown(defaults: UserDefaults = .standard) -> Bool {
        filesAreShown(placement: Self.filesPanelPlacement(defaults: defaults))
    }

    private func filesAreShown(placement: FilesPanelPlacement) -> Bool {
        switch placement {
        case .leading:
            return filesPanelVisible
        case .stacked:
            return filesPanelVisible && (stackedSidebarState?.isVisible ?? true)
        case .rightSidebar:
            return isVisible && mode == .files
        }
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

    private func setMode(_ mode: RightSidebarMode, defaults: UserDefaults = .standard) {
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
    /// fall back like before; with the leading or stacked placement `.files`
    /// is no longer a right-sidebar tab at all, so it (and any fallback) lands
    /// on the first tab the mode bar shows instead.
    private static func availableMode(
        _ mode: RightSidebarMode,
        defaults: UserDefaults
    ) -> RightSidebarMode {
        let filesInRightSidebar = !filesPanelIsDetached(defaults: defaults)
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
