import AppKit
import CmuxFilePreviewCore

/// The editor keeps the diff in view while a file is edited: the working-tree
/// changes against git's index become gutter markers, each revertible, and
/// the selected lines can be handed to the agent prompt as a reference.
extension FilePreviewPanel {
    /// Reads the file's git base off the main actor and diffs the editor text
    /// against it once it arrives. Runs on every load, so a refresh or a save
    /// picks up an index that changed meanwhile.
    func startChangeTracking() {
        changeBaseLoadTask?.cancel()
        let fileURL = fileURL
        let reader = changeBaseReader
        changeBaseLoadTask = Task { [weak self] in
            let base = await Task.detached(priority: .utility) { reader(fileURL) }.value
            guard !Task.isCancelled, let self else { return }
            self.changeBase = base
            self.scheduleChangeHunksRecompute(after: .zero)
        }
    }

    /// Re-reads the base for a tracked file, for when the panel comes back
    /// into use after the index may have moved.
    func refreshChangeBaseIfTracked() {
        guard changeBase != nil else { return }
        startChangeTracking()
    }

    /// Recomputes the hunks after a pause in typing; one diff per keystroke
    /// on a large file would stall the editor. The diff itself runs off the
    /// main actor and is dropped when the text moved on meanwhile.
    func scheduleChangeHunksRecompute(after delay: Duration? = nil) {
        changeRecomputeTask?.cancel()
        guard let base = changeBase?.content else {
            if changeHunks != nil { changeHunks = nil }
            return
        }
        let delay = delay ?? changeRecomputeDelay
        let current = textContent
        let revision = textContentRevision
        changeRecomputeTask = Task { [weak self] in
            if delay > .zero {
                // A bounded debounce, not a poll: the delay is the behaviour.
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            let hunks = await Task.detached(priority: .userInitiated) {
                FilePreviewChangeHunks(base: base, current: current)
            }.value
            guard !Task.isCancelled, let self, self.textContentRevision == revision else { return }
            if self.changeHunks != hunks {
                self.changeHunks = hunks
            }
        }
    }

    /// Awaits the pending base read and recompute; for tests.
    func awaitChangeTracking() async {
        await changeBaseLoadTask?.value
        await changeRecomputeTask?.value
    }

    /// Puts the base lines back in place of `hunk`, through the text view
    /// when it is attached so the change is undoable and goes through the
    /// normal dirty and save path.
    func revertChangeHunk(_ hunk: FilePreviewChangeHunk) {
        let edit = FilePreviewChangeHunks.revertEdit(for: hunk, in: textContent)
        if let textView, textView.string == textContent {
            guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
            textView.textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
            textView.didChangeText()
            return
        }
        updateTextContent((textContent as NSString).replacingCharacters(in: edit.range, with: edit.replacement))
    }

    /// Hands `startLine...endLine` of this file to the workspace's agent
    /// prompt as `path:line` or `path:start-end`, using the repository-relative
    /// path when git knows the file.
    func insertPromptReference(startLine: Int, endLine: Int) {
        let reference = PromptLineReference(
            filePath: changeBase?.relativePath ?? filePath,
            startLine: startLine,
            endLine: endLine
        )
        if let promptInsertionOverride {
            _ = promptInsertionOverride(reference)
            return
        }
        guard let workspace = AppDelegate.shared?.workspaceContainingPanel(
            panelId: id,
            preferredWorkspaceId: workspaceId
        )?.workspace else { return }
        _ = workspace.insertIntoAgentPrompt(reference.promptText)
    }
}
