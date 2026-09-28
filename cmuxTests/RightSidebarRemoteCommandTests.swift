import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TerminalControllerSocketSecurityTests {
    @Test func v1CommandsDriveExistingState() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let windowId = UUID()
        let tabManager = TabManager()
        let fileExplorerState = FileExplorerState()
        fileExplorerState.setVisible(false)
        fileExplorerState.mode = .files

        appDelegate.fileExplorerState = fileExplorerState
        appDelegate.registerMainWindowContextForTesting(
            windowId: windowId,
            tabManager: tabManager,
            fileExplorerState: fileExplorerState
        )
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }

        fileExplorerState.setVisible(false)
        fileExplorerState.mode = .files

        #expect(TerminalController.shared.handleSocketLine("right_sidebar show") == "OK")
        #expect(fileExplorerState.isVisible)

        #expect(TerminalController.shared.handleSocketLine("right_sidebar set find") == "OK")
        #expect(fileExplorerState.mode == .find)
        #expect(fileExplorerState.isVisible)

        #expect(TerminalController.shared.handleSocketLine("right_sidebar set vault --no-focus") == "OK")
        #expect(fileExplorerState.mode == .sessions)

        #expect(TerminalController.shared.handleSocketLine("right_sidebar set sessions --no-focus") == "OK")
        #expect(fileExplorerState.mode == .sessions)

        // Changes (docked diff viewer) and its `diff` alias resolve to the same mode.
        #expect(TerminalController.shared.handleSocketLine("right_sidebar set changes --no-focus") == "OK")
        #expect(fileExplorerState.mode == .changes)

        #expect(TerminalController.shared.handleSocketLine("right_sidebar set sessions --no-focus") == "OK")
        #expect(TerminalController.shared.handleSocketLine("right_sidebar set diff --no-focus") == "OK")
        #expect(fileExplorerState.mode == .changes)

        #expect(TerminalController.shared.handleSocketLine("right_sidebar changes") == "OK")
        #expect(fileExplorerState.mode == .changes)
        #expect(fileExplorerState.isVisible)
        let changesModeResponse = TerminalController.shared.handleSocketLine("right_sidebar mode")
        let changesModeData = try #require(changesModeResponse.data(using: .utf8))
        let changesModePayload = try #require(JSONSerialization.jsonObject(with: changesModeData) as? [String: Any])
        #expect(changesModePayload["mode"] as? String == "changes")

        #expect(TerminalController.shared.handleSocketLine("right_sidebar set sessions --no-focus") == "OK")
        #expect(fileExplorerState.mode == .sessions)

        #expect(TerminalController.shared.handleSocketLine("right_sidebar hide") == "OK")
        #expect(!fileExplorerState.isVisible)

        #expect(TerminalController.shared.handleSocketLine("right_sidebar toggle") == "OK")
        #expect(fileExplorerState.isVisible)

        #expect(TerminalController.shared.handleSocketLine("right_sidebar focus") == "OK")
        #expect(fileExplorerState.isVisible)

        let modeResponse = TerminalController.shared.handleSocketLine("right_sidebar mode")
        let modeData = try #require(modeResponse.data(using: .utf8))
        let modePayload = try #require(JSONSerialization.jsonObject(with: modeData) as? [String: Any])
        #expect(modePayload["visible"] as? Bool == true)
        #expect(modePayload["mode"] as? String == "sessions")

        #expect(TerminalController.shared.handleSocketLine("right_sidebar set unknown").hasPrefix("ERROR:"))
    }

    @Test func filesCommandsRevealTheLeadingFilesPanelWhenDockedLeft() throws {
        let placementKey = SidebarCatalogSection().filesPanelPlacement.userDefaultsKey
        let visibleKey = FileExplorerState.filesPanelVisibleKey
        let defaults = UserDefaults.standard
        let previousPlacement = defaults.object(forKey: placementKey)
        let previousVisible = defaults.object(forKey: visibleKey)
        defaults.set(FilesPanelPlacement.leading.rawValue, forKey: placementKey)
        defaults.set(false, forKey: visibleKey)
        defer {
            if let previousPlacement { defaults.set(previousPlacement, forKey: placementKey) }
            else { defaults.removeObject(forKey: placementKey) }
            if let previousVisible { defaults.set(previousVisible, forKey: visibleKey) }
            else { defaults.removeObject(forKey: visibleKey) }
        }

        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let windowId = UUID()
        let tabManager = TabManager()
        let fileExplorerState = FileExplorerState()
        appDelegate.fileExplorerState = fileExplorerState
        appDelegate.registerMainWindowContextForTesting(
            windowId: windowId,
            tabManager: tabManager,
            fileExplorerState: fileExplorerState
        )
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }

        fileExplorerState.setVisible(false)
        fileExplorerState.mode = .changes
        fileExplorerState.setFilesPanelVisible(false)
        #expect(fileExplorerState.mode == .changes)

        // `right_sidebar set files --no-focus`: reveal without focus.
        #expect(TerminalController.shared.handleSocketLine("right_sidebar set files --no-focus") == "OK")
        #expect(fileExplorerState.filesPanelVisible, "the docked panel is what Files means now")
        #expect(!fileExplorerState.isVisible, "the right sidebar is left alone")
        #expect(fileExplorerState.mode == .changes, "the right sidebar keeps its tab")

        // `right_sidebar files` (focus path through MainWindowFocusController):
        // no window is attached in tests, so focus itself cannot land, but the
        // shared reveal path must still target the panel, not the sidebar.
        fileExplorerState.setFilesPanelVisible(false)
        _ = appDelegate.applyRightSidebarRemoteCommand(.setMode(.files, focus: true))
        #expect(fileExplorerState.filesPanelVisible)
        #expect(!fileExplorerState.isVisible)
        #expect(fileExplorerState.mode == .changes)

        // Other modes still drive the right sidebar as before.
        #expect(TerminalController.shared.handleSocketLine("right_sidebar set find --no-focus") == "OK")
        #expect(fileExplorerState.isVisible)
        #expect(fileExplorerState.mode == .find)
        #expect(fileExplorerState.filesPanelVisible, "showing Find does not close the files panel")

        // The reported state is the right sidebar's, which never lands on Files.
        let modeResponse = TerminalController.shared.handleSocketLine("right_sidebar mode")
        let modeData = try #require(modeResponse.data(using: .utf8))
        let modePayload = try #require(JSONSerialization.jsonObject(with: modeData) as? [String: Any])
        #expect(modePayload["mode"] as? String == "find")
    }

    @Test func v1CommandsRejectCustomSidebarNames() throws {
        let name = "__cmux_test_sidebar_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try withTemporaryCustomSidebarsDirectory { directory in
            let fileURL = directory.appendingPathComponent("\(name).swift")
            try #"Text("Custom")"#.write(to: fileURL, atomically: true, encoding: .utf8)

            let customSidebarsDefaultsKey = "customSidebars.beta.enabled"
            let previousCustomSidebars = UserDefaults.standard.object(forKey: customSidebarsDefaultsKey)
            UserDefaults.standard.set(true, forKey: customSidebarsDefaultsKey)
            defer {
                if let previousCustomSidebars {
                    UserDefaults.standard.set(previousCustomSidebars, forKey: customSidebarsDefaultsKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: customSidebarsDefaultsKey)
                }
            }

            let previousAppDelegate = AppDelegate.shared
            let appDelegate = AppDelegate()
            defer { AppDelegate.shared = previousAppDelegate }

            let windowId = UUID()
            let tabManager = TabManager()
            let fileExplorerState = FileExplorerState()

            appDelegate.fileExplorerState = fileExplorerState
            appDelegate.registerMainWindowContextForTesting(
                windowId: windowId,
                tabManager: tabManager,
                fileExplorerState: fileExplorerState
            )
            defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }
            fileExplorerState.setVisible(false)
            fileExplorerState.mode = .files

            #expect(TerminalController.shared.handleSocketLine("right_sidebar set \(name) --no-focus").hasPrefix("ERROR:"))
            #expect(!fileExplorerState.isVisible)
            #expect(fileExplorerState.mode == .files)
            #expect(fileExplorerState.customSidebarName != name)

            let modeResponse = TerminalController.shared.handleSocketLine("right_sidebar mode")
            let modeData = try #require(modeResponse.data(using: .utf8))
            let modePayload = try #require(JSONSerialization.jsonObject(with: modeData) as? [String: Any])
            #expect(modePayload["visible"] as? Bool == false)
            #expect(modePayload["mode"] as? String == "files")
        }
    }

    @Test func v1ParserProducesRemoteCommands() throws {
#if DEBUG
        let workspaceId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let windowId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let cases: [(String, RightSidebarRemoteRequest)] = [
            (
                "right_sidebar toggle",
                RightSidebarRemoteRequest(command: .toggle, target: RightSidebarRemoteTarget())
            ),
            (
                "right_sidebar show --window=\(windowId.uuidString)",
                RightSidebarRemoteRequest(command: .show, target: RightSidebarRemoteTarget(windowId: windowId, workspaceId: nil))
            ),
            (
                "right_sidebar hide --tab=\(workspaceId.uuidString)",
                RightSidebarRemoteRequest(command: .hide, target: RightSidebarRemoteTarget(windowId: nil, workspaceId: workspaceId))
            ),
            (
                "right_sidebar focus",
                RightSidebarRemoteRequest(command: .focus, target: RightSidebarRemoteTarget())
            ),
            (
                "right_sidebar set find",
                RightSidebarRemoteRequest(command: .setMode(.find, focus: true), target: RightSidebarRemoteTarget())
            ),
            (
                "right_sidebar set vault --no-focus",
                RightSidebarRemoteRequest(command: .setMode(.sessions, focus: false), target: RightSidebarRemoteTarget())
            ),
            (
                "right_sidebar sessions",
                RightSidebarRemoteRequest(command: .setMode(.sessions, focus: true), target: RightSidebarRemoteTarget())
            ),
            (
                "right_sidebar mode",
                RightSidebarRemoteRequest(command: .getState, target: RightSidebarRemoteTarget())
            ),
            (
                "right_sidebar state --workspace \(workspaceId.uuidString) --window \(windowId.uuidString)",
                RightSidebarRemoteRequest(command: .getState, target: RightSidebarRemoteTarget(windowId: windowId, workspaceId: workspaceId))
            ),
        ]

        for (line, expected) in cases {
            let result = TerminalController.shared.parseRightSidebarRemoteRequestForTesting(line)
            #expect(try result.get() == expected, Comment(rawValue: line))
        }

        let invalidCases: [(String, String)] = [
            ("right_sidebar", "Usage: right_sidebar"),
            ("right_sidebar set", "Usage: right_sidebar set"),
            // The accepted `changes` aliases are part of the usage text.
            ("right_sidebar set", "changes|diff|git|custom"),
            ("right_sidebar set unknown", "Unknown right sidebar mode"),
            ("right_sidebar show --no-focus", "Usage: right_sidebar show"),
            ("right_sidebar files --no-focus", "--no-focus is only valid"),
            ("right_sidebar --bad", "Unknown right sidebar option"),
            ("right_sidebar show --tab not-a-uuid", "Invalid right sidebar --tab id"),
            ("right_sidebar show --window", "--window requires an id"),
        ]

        for (line, expectedMessage) in invalidCases {
            switch TerminalController.shared.parseRightSidebarRemoteRequestForTesting(line) {
            case .success(let request):
                Issue.record("Expected parser failure for \(line), got \(request)")
            case .failure(let error):
                #expect(
                    error.message.contains(expectedMessage),
                    "Expected \(line) to contain \(expectedMessage), got \(error.message)"
                )
            }
        }
#endif
    }

    @Test func v1FocusPolicyIsCommandSpecific() throws {
#if DEBUG
        let cases: [(String, Bool)] = [
            ("right_sidebar toggle", true),
            ("right_sidebar show", true),
            ("right_sidebar focus", true),
            ("right_sidebar set find", true),
            ("right_sidebar sessions", true),
            ("right_sidebar set vault --no-focus", false),
            ("right_sidebar hide", false),
            ("right_sidebar mode", false),
            ("right_sidebar state", false),
            ("right_sidebar set unknown", false),
        ]

        for (line, expected) in cases {
            #expect(
                TerminalController.shared.rightSidebarCommandAllowsInAppFocusMutationsForTesting(line) == expected,
                Comment(rawValue: line)
            )
        }
#endif
    }

    @Test func remoteCommandsCanTargetRegisteredWindowOrWorkspaceWithoutFocus() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }
        let windowAId = UUID()
        let windowBId = UUID()
        let managerA = TabManager()
        let managerB = TabManager()
        let managerC = TabManager()
        _ = managerA.addWorkspace(select: false, eagerLoadTerminal: false)
        let workspaceB = managerB.addWorkspace(select: false, eagerLoadTerminal: false)
        let workspaceC = managerC.addWorkspace(select: false, eagerLoadTerminal: false)
        let stateA = FileExplorerState()
        let stateB = FileExplorerState()
        let fallbackState = FileExplorerState()

        stateA.setVisible(false)
        stateA.mode = .files
        stateB.setVisible(false)
        stateB.mode = .files
        fallbackState.setVisible(true)
        fallbackState.mode = .dock
        appDelegate.fileExplorerState = fallbackState

        appDelegate.registerMainWindowContextForTesting(
            windowId: windowAId,
            tabManager: managerA,
            fileExplorerState: stateA
        )
        appDelegate.registerMainWindowContextForTesting(
            windowId: windowBId,
            tabManager: managerB,
            fileExplorerState: stateB
        )
        let windowCId = appDelegate.registerMainWindowContextForTesting(
            tabManager: managerC
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowAId)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowBId)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowCId)
        }

        #expect(appDelegate.applyRightSidebarRemoteCommand(
            .setMode(.find, focus: false),
            target: RightSidebarRemoteTarget(windowId: windowAId, workspaceId: nil)
        ) == .ok)
        #expect(stateA.isVisible)
        #expect(stateA.mode == .find)
        #expect(!stateB.isVisible)
        #expect(stateB.mode == .files)

        #expect(appDelegate.applyRightSidebarRemoteCommand(
            .setMode(.sessions, focus: false),
            target: RightSidebarRemoteTarget(windowId: nil, workspaceId: workspaceB.id)
        ) == .ok)
        #expect(stateB.isVisible)
        #expect(stateB.mode == .sessions)
        #expect(stateA.mode == .find)

        #expect(appDelegate.applyRightSidebarRemoteCommand(
            .hide,
            target: RightSidebarRemoteTarget(windowId: nil, workspaceId: workspaceB.id)
        ) == .ok)
        #expect(!stateB.isVisible)
        #expect(stateA.isVisible)

        switch appDelegate.applyRightSidebarRemoteCommand(
            .toggle,
            target: RightSidebarRemoteTarget(windowId: nil, workspaceId: workspaceB.id)
        ) {
        case .failure(let message):
            #expect(message.contains("target not found"), Comment(rawValue: message))
        case .ok, .state:
            Issue.record("Expected targeted toggle without a window to fail")
        }
        #expect(!stateB.isVisible)

        #expect(appDelegate.applyRightSidebarRemoteCommand(
            .getState,
            target: RightSidebarRemoteTarget(windowId: nil, workspaceId: workspaceB.id)
        ) == .state(.init(visible: false, modeRawValue: "sessions")))

        switch appDelegate.applyRightSidebarRemoteCommand(
            .getState,
            target: RightSidebarRemoteTarget(windowId: nil, workspaceId: workspaceC.id)
        ) {
        case .failure(let message):
            #expect(message.contains("state not available"), Comment(rawValue: message))
        case .ok, .state:
            Issue.record("Expected explicit target without right-sidebar state to fail")
        }

        switch appDelegate.applyRightSidebarRemoteCommand(
            .hide,
            target: RightSidebarRemoteTarget(windowId: nil, workspaceId: UUID())
        ) {
        case .failure(let message):
            #expect(message.contains("target not found"), Comment(rawValue: message))
        case .ok, .state:
            Issue.record("Expected missing workspace target to fail")
        }
    }

    private func withTemporaryCustomSidebarsDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebars-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try CmuxExtensionSidebarSelection.withCustomSidebarsDirectoryForTesting(directory) {
            try body(directory)
        }
    }
}
