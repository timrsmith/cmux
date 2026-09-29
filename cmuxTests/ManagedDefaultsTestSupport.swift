import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Shared helpers for suites that load a `cmux.json` through
/// `KeyboardShortcutSettingsFileStore`, which applies the file's managed
/// defaults to `UserDefaults.standard` (the test host's real defaults).
///
/// Every `XCTestCase` has the helpers through the conformance below; a Swift
/// Testing suite adopts the protocol itself:
///
/// ```swift
/// @Suite(.serialized) struct MySettingsTests: ManagedDefaultsTestSupport { ... }
/// ```
protocol ManagedDefaultsTestSupport {}

extension XCTestCase: ManagedDefaultsTestSupport {}

extension ManagedDefaultsTestSupport {
    /// The keys the settings-file store writes on every import: its backup
    /// record and the list of managed defaults it has applied.
    private static var settingsFileBookkeepingKeys: [String] {
        ["cmux.settingsFile.backups.v1", "cmux.settingsFile.importedManagedDefaults.v1"]
    }

    /// Runs `body` against `UserDefaults.standard` with the settings-file
    /// bookkeeping keys and `keys` removed first, then restores each of those
    /// keys to the value it had before, whether `body` throws or not.
    ///
    /// Pass the managed keys the body's settings file writes as `keys`, so a
    /// value left in the host's defaults cannot satisfy or break an assertion.
    func withCleanManagedDefaults(clearing keys: [String] = [], _ body: (UserDefaults) throws -> Void) throws {
        let defaults = UserDefaults.standard
        let allKeys = keys + Self.settingsFileBookkeepingKeys
        let previousValues = allKeys.reduce(into: [String: Any]()) { values, key in
            values[key] = defaults.object(forKey: key)
        }
        defer {
            for key in allKeys {
                if let value = previousValues[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        for key in allKeys {
            defaults.removeObject(forKey: key)
        }
        try body(defaults)
    }

    /// Writes `contents` as a temporary `cmux.json` and loads it once through
    /// `KeyboardShortcutSettingsFileStore` without watching, applying the
    /// managed defaults it declares to `UserDefaults.standard`.
    ///
    /// Call it on the main thread (XCTest does; a Swift Testing test needs
    /// `@MainActor`): the store writes managed defaults on the main queue and
    /// defers the write when loaded elsewhere, so an assertion right after
    /// the call would read stale defaults.
    func loadSettingsFile(_ contents: String) throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "managed-defaults-settings-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try contents.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
    }
}
