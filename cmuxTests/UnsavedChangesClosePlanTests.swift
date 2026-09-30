import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The pure decision behind the Save / Don't Save / Cancel prompt.
struct UnsavedChangesClosePlanTests {
    @Test
    func nothingDirtyNeedsNoPrompt() {
        let plan = UnsavedChangesClosePlan(fileNames: [])
        #expect(!plan.requiresPrompt)
        #expect(plan.prompt == nil)
    }

    @Test
    func oneDirtyFileNamesItInTheTitle() throws {
        let plan = UnsavedChangesClosePlan(fileNames: ["notes.md"])
        let prompt = try #require(plan.prompt)
        #expect(prompt.title.contains("notes.md"))
        #expect(prompt.title.hasSuffix("?"))
        #expect(prompt.details == nil)
        #expect(!prompt.message.isEmpty)
        #expect(prompt.fileNames == ["notes.md"])
    }

    @Test
    func severalDirtyFilesCountThemInTheTitleAndListThemInTheMessage() throws {
        let plan = UnsavedChangesClosePlan(fileNames: ["a.md", "b.txt", "c.swift"])
        let prompt = try #require(plan.prompt)
        #expect(prompt.title.contains("3"))
        #expect(!prompt.title.contains("a.md"))
        for name in ["a.md", "b.txt", "c.swift"] {
            #expect(prompt.message.contains("• \(name)"))
        }
        let details = try #require(prompt.details)
        #expect(details.components(separatedBy: "\n").count == 3)
        #expect(prompt.fileNames == ["a.md", "b.txt", "c.swift"])
    }

    @Test(arguments: [
        (UnsavedChangesPromptResponse.save, UnsavedChangesClosePlan.Outcome.saveThenProceed),
        (UnsavedChangesPromptResponse.dontSave, UnsavedChangesClosePlan.Outcome.proceed),
        (UnsavedChangesPromptResponse.cancel, UnsavedChangesClosePlan.Outcome.cancel)
    ])
    func answersMapOntoTheClose(response: UnsavedChangesPromptResponse, outcome: UnsavedChangesClosePlan.Outcome) {
        let plan = UnsavedChangesClosePlan(fileNames: ["notes.md"])
        #expect(plan.outcome(for: response) == outcome)
    }

    @Test
    func saveAndDontSaveConfirmTheCloseSoTheCloseWarningMustNotAskAgain() {
        let plan = UnsavedChangesClosePlan(fileNames: ["notes.md"])
        #expect(plan.confirmsClose(for: .save))
        #expect(plan.confirmsClose(for: .dontSave))
        #expect(!plan.confirmsClose(for: .cancel))
    }

    @Test
    func thePromptIsNotAPreferenceAndOffersNoDontAskAgain() {
        #expect(!UnsavedChangesClosePlan(fileNames: ["notes.md"]).offersDontAskAgain)
    }
}
