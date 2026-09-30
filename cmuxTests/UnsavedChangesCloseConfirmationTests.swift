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
        #expect(presenter.saveFailures.first == UnsavedChangesSaveError(fileName: url.lastPathComponent).localizedDescription,
                "a write that failed is reported as a failed save")
        #expect(panel.isDirty)
        #expect(try String(contentsOf: url, encoding: .utf8) == "original")
    }

    @Test
    func saveWaitsForTheRunningSaveThenWritesTheNewerEdits() async throws {
        // The first write is held until the prompt is answered, so the
        // close-time save finds a save in flight and a buffer edited after it
        // started. Nothing failed: the newer edits must reach the file.
        let firstWriteGate = AsyncStream<Void>.makeStream()
        let (panel, url) = try await UnsavedChangesTestPanels.makeLoadedFilePreviewPanel(contents: "original") { path in
            FilePreviewPanel(
                workspaceId: UUID(),
                filePath: path,
                startFileWatcher: false,
                textSaver: { content, fileURL, encoding in
                    if content == "first" {
                        for await _ in firstWriteGate.stream { break }
                    }
                    return await FilePreviewTextSaver.save(content: content, to: fileURL, encoding: encoding)
                },
                modeResolver: { _ in .text }
            )
        }
        defer { panel.close(); try? FileManager.default.removeItem(at: url) }
        panel.updateTextContent("first")
        let firstSave = try #require(panel.saveTextContent())
        panel.updateTextContent("second")
        #expect(panel.saveTextContent() == nil, "a second save does not start while the first is running")
        let presenter = RecordingUnsavedChangesPresenter(responses: [.save])
        presenter.onPrompt = { firstWriteGate.continuation.yield() }
        let confirmation = UnsavedChangesCloseConfirmation(presenter: presenter)

        #expect(await confirmation.confirmClose(of: [panel]))
        await firstSave.value
        #expect(presenter.prompts.count == 1)
        #expect(presenter.saveFailures.isEmpty, "\(presenter.saveFailures)")
        #expect(!panel.isDirty)
        #expect(try String(contentsOf: url, encoding: .utf8) == "second")
    }

    @Test
    func unavailableSavingIsReportedAsSuchNotAsAFailedWrite() async throws {
        let (panel, url) = try await UnsavedChangesTestPanels.makeLoadedFilePreviewPanel(contents: "original")
        defer { panel.close(); try? FileManager.default.removeItem(at: url) }
        panel.updateTextContent("edited")
        #expect(panel.isDirty)
        // A cloud preview lease turns the panel into a read-only preview: no
        // write can start, so nothing "failed".
        let cache = CloudFilePreviewCache(directory: FileManager.default.temporaryDirectory)
        panel.cloudPreviewLease = CloudFilePreviewLease(
            url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            remotePath: "/remote/\(url.lastPathComponent)",
            remoteIdentity: "test-vm",
            cache: cache
        )
        let presenter = RecordingUnsavedChangesPresenter(responses: [.save])
        let confirmation = UnsavedChangesCloseConfirmation(presenter: presenter)

        #expect(await !confirmation.confirmClose(of: [panel]))
        #expect(presenter.saveFailures.count == 1)
        let message = try #require(presenter.saveFailures.first)
        #expect(message.contains(url.lastPathComponent))
        #expect(message != UnsavedChangesSaveError(fileName: url.lastPathComponent).localizedDescription,
                "no write failed, so the message must not say the file could not be saved")
        #expect(message == UnsavedChangesSaveError(fileName: url.lastPathComponent, reason: .savingUnavailable).localizedDescription)
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
