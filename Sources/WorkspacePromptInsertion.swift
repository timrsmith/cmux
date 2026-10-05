import AppKit

extension Workspace {
    /// Puts `text` where this workspace's agent reads its next prompt: the
    /// TextBox of the terminal that takes input when it is showing, otherwise
    /// pasted into that terminal. When the focused panel is not a terminal
    /// (the diff pane that asked), the terminal running a live agent comes
    /// first, then the first terminal in sidebar order.
    @discardableResult
    func insertIntoAgentPrompt(_ text: String) -> Bool {
        guard !text.isEmpty, let panel = agentPromptTerminalPanel() else { return false }
        if panel.isTextBoxActive, let textView = panel.textBoxInputView {
            textView.window?.makeFirstResponder(textView)
            textView.insertText(text, replacementRange: textView.selectedRange())
            return true
        }
        return panel.sendText(text)
    }

    private func agentPromptTerminalPanel() -> TerminalPanel? {
        if let target = focusedTerminalInputTarget() {
            return target.panel
        }
        let terminals = sidebarOrderedPanelIds().compactMap { panels[$0] as? TerminalPanel }
        return terminals.first { SharedLiveAgentIndex.shared.snapshot(workspaceId: id, panelId: $0.id) != nil }
            ?? terminals.first
    }
}
