import AppKit
import CmuxSettings
import Foundation
import SwiftUI
import Testing

@testable import CmuxSettingsUI

/// A view's first body reads a `@LiveSetting`'s stored value, not the catalog
/// default. The wrapper seeds its `@State` synchronously from `UserDefaults`
/// instead of waiting for the store stream's first element, so a view that
/// lays out from the setting (the Files panel placement) never renders the
/// default first and swaps a frame later.
@MainActor
@Suite(.serialized) struct LiveSettingInitialValueTests {
    final class FirstBodyRecorder {
        var values: [Bool] = []
    }

    private struct Probe: View {
        @LiveSetting(\.betaFeatures.extensions) private var extensionsEnabled
        let recorder: FirstBodyRecorder

        var body: some View {
            recorder.values.append(extensionsEnabled)
            return Color.clear
        }
    }

    @Test func firstBodyReadsTheStoredValue() {
        let key = SettingCatalog().betaFeatures.extensions
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key.userDefaultsKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: key.userDefaultsKey)
            } else {
                defaults.removeObject(forKey: key.userDefaultsKey)
            }
        }
        let stored = !key.defaultValue
        defaults.set(stored, forKey: key.userDefaultsKey)

        // Hosted the way the main window hosts SwiftUI: the first layout pass
        // runs synchronously, before any run-loop turn could deliver a stream
        // element. No `SettingsRuntime` is injected, so the value the body
        // sees is exactly the wrapper's seed.
        let recorder = FirstBodyRecorder()
        let hosting = NSHostingController(rootView: Probe(recorder: recorder))
        let window = NSWindow(contentViewController: hosting)
        defer { window.close() }
        window.setContentSize(NSSize(width: 200, height: 200))
        window.contentView?.layoutSubtreeIfNeeded()

        #expect(recorder.values.first == stored, "first body saw \(recorder.values)")
    }
}
