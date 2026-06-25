import AppKit
import BiscottiTestSupport
import DataStore
import Foundation
import Intelligence
import LocalLLM
import SummaryPromptUI
import Testing
@testable import AppCore
@testable import MeetingDetailUI

// MARK: - Regenerate markEdited wiring

/// Tests that `MeetingDetailViewModel.regenerate(withPrompt:alsoSave:)` computes
/// the `markResultEdited` flag correctly across the three ownership cases described
/// in the spec (architecture §5.2, functional_spec §4.3).
@Suite("MeetingDetailViewModel -- regenerate markEdited wiring")
@MainActor
struct RegenerateWiringTests {
    // MARK: - Helpers

    /// Creates a meeting with a transcript and AI-generated summary, returning
    /// the fixture and meeting ID. The meeting's `editedSummary` is `false` (AI
    /// generated) so the summary-turn guard (`doSummary = !edited || force`)
    /// allows regeneration.
    private func makeFixtureWithSummary() async throws -> (CoreFixture, UUID) {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "RegenerateWiringTests"
        )
        let meetingID = try await fix.createMeetingWithAudio()
        let result = FakeTranscriber.defaultResult
        let transcriptID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(
            transcriptID, for: meetingID
        )
        try await fix.store.applyGeneratedSummary(
            "Original AI summary", for: meetingID
        )
        return (fix, meetingID)
    }

    // MARK: - Case 1: No edit (prompt == effective global, alsoSave false)

    @Test("regenerate with default prompt marks editedSummary false")
    func regenerateWithDefaultPromptMarksEditedFalse() async throws {
        let (fix, meetingID) = try await makeFixtureWithSummary()
        defer { fix.cleanup() }

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // The effective prompt is the default (no custom prompt saved)
        let effective = await fix.core.effectiveSummaryPrompt()

        // Regenerate with the same prompt text (no edits)
        viewModel.regenerate(withPrompt: effective, alsoSave: false)

        // Wait for the async Task inside regenerate to complete
        try await Task.sleep(for: .milliseconds(200))

        // The result should NOT be marked as edited
        let detail = try await fix.store.meetingDetail(id: meetingID)
        #expect(detail?.editedSummary == false)
    }

    // MARK: - Case 2: Edited, alsoSave off (prompt != effective, alsoSave false)

    @Test("regenerate with custom prompt and no save marks editedSummary true")
    func regenerateWithCustomPromptNoSaveMarksEditedTrue() async throws {
        let (fix, meetingID) = try await makeFixtureWithSummary()
        defer { fix.cleanup() }

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Regenerate with a custom prompt, NOT saving it
        viewModel.regenerate(
            withPrompt: "Custom one-off prompt for this meeting",
            alsoSave: false
        )

        // Wait for the async Task inside regenerate to complete
        try await Task.sleep(for: .milliseconds(200))

        // The result SHOULD be marked as edited (meeting-specific custom prompt)
        let detail = try await fix.store.meetingDetail(id: meetingID)
        #expect(detail?.editedSummary == true)
    }

    // MARK: - Case 3: Edited, alsoSave on (prompt != effective, alsoSave true)

    @Test("regenerate with custom prompt and save marks editedSummary false")
    func regenerateWithCustomPromptAndSaveMarksEditedFalse() async throws {
        let (fix, meetingID) = try await makeFixtureWithSummary()
        defer { fix.cleanup() }

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Regenerate with a custom prompt AND save it as the new default
        viewModel.regenerate(
            withPrompt: "New default prompt for all meetings",
            alsoSave: true
        )

        // Wait for the async Task inside regenerate to complete
        try await Task.sleep(for: .milliseconds(200))

        // The result should NOT be marked as edited because the save makes
        // the used prompt == the global prompt
        let detail = try await fix.store.meetingDetail(id: meetingID)
        #expect(detail?.editedSummary == false)

        // Verify the prompt was actually saved globally
        let saved = await fix.core.effectiveSummaryPrompt()
        #expect(saved == "New default prompt for all meetings")
    }

    // MARK: - Sheet dismissal

    @Test("regenerate dismisses the sheet")
    func regenerateDismissesSheet() async throws {
        let (fix, meetingID) = try await makeFixtureWithSummary()
        defer { fix.cleanup() }

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        viewModel.showResummarizeSheet = true
        let effective = await fix.core.effectiveSummaryPrompt()
        viewModel.regenerate(withPrompt: effective, alsoSave: false)

        // Sheet should be dismissed synchronously
        #expect(viewModel.showResummarizeSheet == false)
        // Tab should switch to summary
        #expect(viewModel.selectedTab == .summary)
    }

    // MARK: - presentResummarizeSheet model initialization

    @Test("presentResummarizeSheet builds model with correct mode and text")
    func presentResummarizeSheetBuildsModel() async throws {
        let (fix, meetingID) = try await makeFixtureWithSummary()
        defer { fix.cleanup() }

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        viewModel.presentResummarizeSheet()

        // Wait for the async Task inside presentResummarizeSheet
        try await Task.sleep(for: .milliseconds(100))

        #expect(viewModel.showResummarizeSheet == true)

        let model = try #require(viewModel.summaryPromptModel)
        let effective = await fix.core.effectiveSummaryPrompt()

        #expect(model.workingText == effective)
        #expect(model.initialText == effective)
        #expect(model.defaultText == fix.core.defaultSummaryPrompt)

        // Mode should be perMeeting
        if case let .perMeeting(reference, summaryWasEdited) = model.mode {
            #expect(reference.title == viewModel.detail?.title ?? "")
            #expect(summaryWasEdited == viewModel.editedSummary)
        } else {
            Issue.record("Expected perMeeting mode")
        }
    }
}
