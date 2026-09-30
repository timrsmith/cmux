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
        let (panel, url) = try await UnsavedChangesTestPanels.makeLoadedMarkdownPanel()
        defer { panel.close(); try? FileManager.default.removeItem(at: url) }
        let presenter = RecordingUnsavedChangesPresenter(responses: [.cancel])
        let confirmation = UnsavedChangesCloseConfirmation(presenter: presenter)

        #expect(await confirmation.confirmClose(of: [panel]))
        #expect(presenter.prompts.isEmpty)
        #expect(confirmation.unresolvedPanels(in: [panel]).isEmpty)
    }

    @Test
    func cancelKeepsTheEditsAndCancelsTheClose() async throws {
        let (panel, url) = try await UnsavedChangesTestPanels.makeLoadedMarkdownPanel()
        defer { panel.close(); try? FileManager.default.removeItem(at: url) }
        panel.updateTextContent("# Original\n\nEdited.\n")
        let presenter = RecordingUnsavedChangesPresenter(responses: [.cancel])
        let confirmation = UnsavedChangesCloseConfirmation(presenter: presenter)

        #expect(await !confirmation.confirmClose(of: [panel]))
        #expect(presenter.prompts.count == 1)
        #expect(presenter.prompts.first?.title.contains(url.lastPathComponent) == true)
        #expect(panel.isDirty)
        #expect(try String(contentsOf: url, encoding: .utf8) == "# Original\n")
    }

    @Test
    func dontSaveProceedsWithoutWriting() async throws {
        let (panel, url) = try await UnsavedChangesTestPanels.makeLoadedMarkdownPanel()
        defer { panel.close(); try? FileManager.default.removeItem(at: url) }
        panel.updateTextContent("# Original\n\nEdited.\n")
        let presenter = RecordingUnsavedChangesPresenter(responses: [.dontSave])
        let confirmation = UnsavedChangesCloseConfirmation(presenter: presenter)

        #expect(await confirmation.confirmClose(of: [panel]))
        #expect(presenter.prompts.count == 1)
        #expect(panel.isDirty)
        #expect(try String(contentsOf: url, encoding: .utf8) == "# Original\n")
    }

    @Test
    func saveWritesEveryDirtyEditorWithOnePromptThenProceeds() async throws {
        let (markdown, markdownURL) = try await UnsavedChangesTestPanels.makeLoadedMarkdownPanel()
        defer { markdown.close(); try? FileManager.default.removeItem(at: markdownURL) }
        let (preview, previewURL) = try await UnsavedChangesTestPanels.makeLoadedFilePreviewPanel()
        defer { preview.close(); try? FileManager.default.removeItem(at: previewURL) }
        markdown.updateTextContent("# Saved\n")
        preview.updateTextContent("saved text")
        let presenter = RecordingUnsavedChangesPresenter(responses: [.save])
        let confirmation = UnsavedChangesCloseConfirmation(presenter: presenter)

        #expect(await confirmation.confirmClose(of: [markdown, preview]))
        #expect(presenter.prompts.count == 1)
        let prompt = try #require(presenter.prompts.first)
        #expect(prompt.title.contains("2"))
        #expect(prompt.details == "• \(markdownURL.lastPathComponent)\n• \(previewURL.lastPathComponent)")
        #expect(!markdown.isDirty)
        #expect(!preview.isDirty)
        #expect(try String(contentsOf: markdownURL, encoding: .utf8) == "# Saved\n")
        #expect(try String(contentsOf: previewURL, encoding: .utf8) == "saved text")
    }

    @Test
    func saveFailureShowsTheErrorAndCancelsTheClose() async throws {
        let (panel, url) = try await UnsavedChangesTestPanels.makeLoadedFilePreviewPanel(contents: "original") { path in
            FilePreviewPanel(
                workspaceId: UUID(),
                filePath: path,
                startFileWatcher: false,
                textSaver: { _, _, _ in .failed(fileExists: true) },
                modeResolver: { _ in .text }
            )
        }
        defer { panel.close(); try? FileManager.default.removeItem(at: url) }
        panel.updateTextContent("edited")
        let presenter = RecordingUnsavedChangesPresenter(responses: [.save])
        let confirmation = UnsavedChangesCloseConfirmation(presenter: presenter)

        #expect(await !confirmation.confirmClose(of: [panel]))
        #expect(presenter.prompts.count == 1)
        #expect(presenter.saveFailures.count == 1)
        #expect(presenter.saveFailures.first?.contains(url.lastPathComponent) == true)
        #expect(panel.isDirty)
        #expect(try String(contentsOf: url, encoding: .utf8) == "original")
    }

    @Test
    func gateIsClearWhenNothingIsDirtySoTheCallerContinues() async throws {
        let (panel, url) = try await UnsavedChangesTestPanels.makeLoadedMarkdownPanel()
        defer { panel.close(); try? FileManager.default.removeItem(at: url) }
        let confirmation = UnsavedChangesCloseConfirmation(presenter: RecordingUnsavedChangesPresenter())
        var retried = false

        #expect(confirmation.gate(for: [panel], retry: { retried = true }) == .clear)
        #expect(!retried)
        #expect(confirmation.inFlightResolution == nil)
    }

    @Test
    func gateRetriesWithTheCloseConfirmedThenForgetsTheAnswer() async throws {
        let (panel, url) = try await UnsavedChangesTestPanels.makeLoadedMarkdownPanel()
        defer { panel.close(); try? FileManager.default.removeItem(at: url) }
        panel.updateTextContent("# Original\n\nEdited.\n")
        let presenter = RecordingUnsavedChangesPresenter(responses: [.dontSave])
        let confirmation = UnsavedChangesCloseConfirmation(presenter: presenter)
        var retries = 0
        var gateDuringRetry = UnsavedChangesCloseConfirmation.Gate.clear
        var unresolvedDuringRetry = 1

        let gate = confirmation.gate(
            for: [panel],
            retry: {
                retries += 1
                gateDuringRetry = confirmation.gate(for: [panel], retry: {})
                unresolvedDuringRetry = confirmation.unresolvedPanels(in: [panel]).count
            },
            onCancel: { Issue.record("Don't Save must not cancel") }
        )
        #expect(gate == .deferred)
        let resolution = try #require(confirmation.inFlightResolution)
        await resolution.value

        #expect(retries == 1)
        #expect(gateDuringRetry == .confirmed)
        #expect(unresolvedDuringRetry == 0)
        #expect(!confirmation.isCloseConfirmed(for: [panel]))
        #expect(confirmation.unresolvedPanels(in: [panel]).count == 1)
        #expect(confirmation.inFlightResolution == nil)
    }

    @Test
    func gateCancelRunsOnCancelAndNeverRetries() async throws {
        let (panel, url) = try await UnsavedChangesTestPanels.makeLoadedMarkdownPanel()
        defer { panel.close(); try? FileManager.default.removeItem(at: url) }
        panel.updateTextContent("# Original\n\nEdited.\n")
        let confirmation = UnsavedChangesCloseConfirmation(
            presenter: RecordingUnsavedChangesPresenter(responses: [.cancel])
        )
        var cancelled = false

        #expect(confirmation.gate(
            for: [panel],
            retry: { Issue.record("Cancel must not retry") },
            onCancel: { cancelled = true }
        ) == .deferred)
        let resolution = try #require(confirmation.inFlightResolution)
        await resolution.value

        #expect(cancelled)
        #expect(panel.isDirty)
    }
}
