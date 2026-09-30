import AppKit
import SwiftUI

/// A segmented control whose segments show an SF Symbol beside their title.
///
/// SwiftUI's `.segmented` picker on macOS shows either a segment's text or
/// its image, never both, so a choice that is easiest to read as icon plus
/// word (such as ``FilesPanelPlacement``) goes through `NSSegmentedControl`
/// directly. Segments are laid out in `options` order; the selected segment
/// tracks `selection` and a click writes the option back through it.
///
/// ```swift
/// IconLabeledSegmentedPicker(
///     options: FilesPanelPlacement.allCases,
///     selection: $placement,
///     title: \.localizedTitle,
///     symbolName: \.symbolName
/// )
/// ```
public struct IconLabeledSegmentedPicker<Option: Hashable>: NSViewRepresentable {
    /// The choices, in segment order.
    public let options: [Option]
    /// The selected option; changes in either direction stay in step.
    @Binding public var selection: Option
    /// The label shown in an option's segment.
    public let title: (Option) -> String
    /// The SF Symbol shown before an option's title.
    public let symbolName: (Option) -> String

    /// - Parameters:
    ///   - options: The choices, in segment order.
    ///   - selection: The selected option.
    ///   - title: The label shown in an option's segment.
    ///   - symbolName: The SF Symbol shown before an option's title.
    public init(
        options: [Option],
        selection: Binding<Option>,
        title: @escaping (Option) -> String,
        symbolName: @escaping (Option) -> String
    ) {
        self.options = options
        _selection = selection
        self.title = title
        self.symbolName = symbolName
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(options: options, selection: $selection)
    }

    public func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentStyle = .automatic
        control.trackingMode = .selectOne
        control.controlSize = .regular
        control.segmentCount = options.count
        for (index, option) in options.enumerated() {
            control.setLabel(title(option), forSegment: index)
            control.setImage(NSImage(systemSymbolName: symbolName(option), accessibilityDescription: nil), forSegment: index)
            control.setImageScaling(.scaleProportionallyDown, forSegment: index)
        }
        control.target = context.coordinator
        control.action = #selector(Coordinator.segmentDidChange(_:))
        control.setContentHuggingPriority(.required, for: .horizontal)
        applySelection(to: control)
        return control
    }

    public func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        applySelection(to: control)
    }

    private func applySelection(to control: NSSegmentedControl) {
        guard let index = options.firstIndex(of: selection), control.selectedSegment != index else { return }
        control.selectedSegment = index
    }

    /// Routes the control's action back into the SwiftUI binding.
    @MainActor
    public final class Coordinator: NSObject {
        let options: [Option]
        var selection: Binding<Option>

        init(options: [Option], selection: Binding<Option>) {
            self.options = options
            self.selection = selection
        }

        @objc func segmentDidChange(_ control: NSSegmentedControl) {
            guard options.indices.contains(control.selectedSegment) else { return }
            let next = options[control.selectedSegment]
            if selection.wrappedValue != next {
                selection.wrappedValue = next
            }
        }
    }
}
