import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The shared prompt-and-save flow, driven with real editor panels and a
/// recording presenter so no alert is shown.
@MainActor
@Suite(.serialized)
struct UnsavedChangesCloseConfirmationTests {
    @Test
    func nothingDirtyProceedsWithoutAsking() async throws {
        let (panel, url) = try await makeLoadedMarkdownPanel()
        defer { panel.close(); try? FileManager.default.removeItem(at: url) }
        let presenter = RecordingUnsavedChangesPresenter(responses: [.cancel])
        let confirmation = UnsavedChangesCloseConfirmation(presenter: presenter)

        #expect(await confirmation.confirmClose(of: [panel]) == .proceed)
        #expect(presenter.prompts.isEmpty)
        #expect(confirmation.unresolvedPanels(in: [panel]).isEmpty)
    }

    @Test
    func cancelKeepsTheEditsAndCancelsTheClose() async throws {
        let (panel, url) = try await makeLoadedMarkdownPanel()
        defer { panel.close(); try? FileManager.default.removeItem(at: url) }
        panel.updateTextContent("# Original\n\nEdited.\n")
        let presenter = RecordingUnsavedChangesPresenter(responses: [.cancel])
        let confirmation = UnsavedChangesCloseConfirmation(presenter: presenter)

        #expect(await confirmation.confirmClose(of: [panel]) == .cancel)
        #expect(presenter.prompts.count == 1)
        #expect(presenter.prompts.first?.fileNames == [url.lastPathComponent])
        #expect(panel.isDirty)
        #expect(try String(contentsOf: url, encoding: .utf8) == "# Original\n")
    }

    @Test
    func dontSaveProceedsWithoutWriting() async throws {
        let (panel, url) = try await makeLoadedMarkdownPanel()
        defer { panel.close(); try? FileManager.default.removeItem(at: url) }
        panel.updateTextContent("# Original\n\nEdited.\n")
        let presenter = RecordingUnsavedChangesPresenter(responses: [.dontSave])
        let confirmation = UnsavedChangesCloseConfirmation(presenter: presenter)

        #expect(await confirmation.confirmClose(of: [panel]) == .proceed)
        #expect(presenter.prompts.count == 1)
        #expect(panel.isDirty)
        #expect(try String(contentsOf: url, encoding: .utf8) == "# Original\n")
    }

    @Test
    func saveWritesEveryDirtyEditorWithOnePromptThenProceeds() async throws {
        let (markdown, markdownURL) = try await makeLoadedMarkdownPanel()
        defer { markdown.close(); try? FileManager.default.removeItem(at: markdownURL) }
        let (preview, previewURL) = try await makeLoadedFilePreviewPanel()
        defer { preview.close(); try? FileManager.default.removeItem(at: previewURL) }
        markdown.updateTextContent("# Saved\n")
        preview.updateTextContent("saved text")
        let presenter = RecordingUnsavedChangesPresenter(responses: [.save])
        let confirmation = UnsavedChangesCloseConfirmation(presenter: presenter)

        #expect(await confirmation.confirmClose(of: [markdown, preview]) == .proceed)
        #expect(presenter.prompts.count == 1)
        #expect(presenter.prompts.first?.fileNames == [markdownURL.lastPathComponent, previewURL.lastPathComponent])
        #expect(presenter.prompts.first?.title.contains("2") == true)
        #expect(!markdown.isDirty)
        #expect(!preview.isDirty)
        #expect(try String(contentsOf: markdownURL, encoding: .utf8) == "# Saved\n")
        #expect(try String(contentsOf: previewURL, encoding: .utf8) == "saved text")
    }

    @Test
    func saveFailureShowsTheErrorAndCancelsTheClose() async throws {
        let url = try UnsavedChangesTestFiles.temporaryTextFile(contents: "original")
        defer { try? FileManager.default.removeItem(at: url) }
        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: url.path,
            startFileWatcher: false,
            textSaver: { _, _, _ in .failed(fileExists: true) },
            modeResolver: { _ in .text }
        )
        defer { panel.close() }
        await panel.loadTextContent().value
        panel.updateTextContent("edited")
        let presenter = RecordingUnsavedChangesPresenter(responses: [.save])
        let confirmation = UnsavedChangesCloseConfirmation(presenter: presenter)

        #expect(await confirmation.confirmClose(of: [panel]) == .cancel)
        #expect(presenter.prompts.count == 1)
        #expect(presenter.saveFailures.count == 1)
        #expect(presenter.saveFailures.first?.contains(url.lastPathComponent) == true)
        #expect(panel.isDirty)
        #expect(try String(contentsOf: url, encoding: .utf8) == "original")
    }

    @Test
    func deferReturnsFalseWhenNothingIsDirtySoTheCallerContinues() async throws {
        let (panel, url) = try await makeLoadedMarkdownPanel()
        defer { panel.close(); try? FileManager.default.removeItem(at: url) }
        let confirmation = UnsavedChangesCloseConfirmation(presenter: RecordingUnsavedChangesPresenter())
        var retried = false

        #expect(!confirmation.deferCloseIfNeeded(for: [panel], retry: { retried = true }))
        #expect(!retried)
        #expect(confirmation.inFlightResolution == nil)
    }

    @Test
    func deferRetriesWithTheCloseConfirmedThenForgetsTheAnswer() async throws {
        let (panel, url) = try await makeLoadedMarkdownPanel()
        defer { panel.close(); try? FileManager.default.removeItem(at: url) }
        panel.updateTextContent("# Original\n\nEdited.\n")
        let presenter = RecordingUnsavedChangesPresenter(responses: [.dontSave])
        let confirmation = UnsavedChangesCloseConfirmation(presenter: presenter)
        var retries = 0
        var closeConfirmedDuringRetry = false
        var unresolvedDuringRetry = 1

        let deferred = confirmation.deferCloseIfNeeded(
            for: [panel],
            retry: {
                retries += 1
                closeConfirmedDuringRetry = confirmation.isCloseConfirmed(for: [panel])
                unresolvedDuringRetry = confirmation.unresolvedPanels(in: [panel]).count
            },
            onCancel: { Issue.record("Don't Save must not cancel") }
        )
        #expect(deferred)
        let resolution = try #require(confirmation.inFlightResolution)
        await resolution.value

        #expect(retries == 1)
        #expect(closeConfirmedDuringRetry)
        #expect(unresolvedDuringRetry == 0)
        #expect(!confirmation.isCloseConfirmed(for: [panel]))
        #expect(confirmation.unresolvedPanels(in: [panel]).count == 1)
        #expect(confirmation.inFlightResolution == nil)
    }

    @Test
    func deferCancelRunsOnCancelAndNeverRetries() async throws {
        let (panel, url) = try await makeLoadedMarkdownPanel()
        defer { panel.close(); try? FileManager.default.removeItem(at: url) }
        panel.updateTextContent("# Original\n\nEdited.\n")
        let confirmation = UnsavedChangesCloseConfirmation(
            presenter: RecordingUnsavedChangesPresenter(responses: [.cancel])
        )
        var cancelled = false

        #expect(confirmation.deferCloseIfNeeded(
            for: [panel],
            retry: { Issue.record("Cancel must not retry") },
            onCancel: { cancelled = true }
        ))
        let resolution = try #require(confirmation.inFlightResolution)
        await resolution.value

        #expect(cancelled)
        #expect(panel.isDirty)
    }

    private func makeLoadedMarkdownPanel() async throws -> (MarkdownPanel, URL) {
        let url = try UnsavedChangesTestFiles.temporaryMarkdownFile(contents: "# Original\n")
        let panel = MarkdownPanel(workspaceId: UUID(), filePath: url.path)
        if let load = panel.loadTextContent() {
            await load.value
        }
        return (panel, url)
    }

    private func makeLoadedFilePreviewPanel() async throws -> (FilePreviewPanel, URL) {
        let url = try UnsavedChangesTestFiles.temporaryTextFile(contents: "original text")
        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: url.path,
            startFileWatcher: false,
            modeResolver: { _ in .text }
        )
        await panel.loadTextContent().value
        return (panel, url)
    }
}
