import AppKit
import BiscottiTestSupport
import DataStore
import Foundation
import Intelligence
import LocalLLM
import Testing
@testable import AppCore
@testable import MeetingDetailUI

// MARK: - Tab enum

@Suite("Summary tab -- Tab enum ordering")
struct SummaryTabEnumTests {
    @Test("Tab.summary is the first case in allCases")
    @MainActor
    func summaryIsFirstTab() {
        let allTabs = MeetingDetailViewModel.Tab.allCases
        #expect(allTabs.first == .summary)
        #expect(allTabs.count == 3)
        #expect(allTabs == [.summary, .transcript, .notes])
    }

    @Test("Default selectedTab is .summary")
    @MainActor
    func defaultTabIsSummary() throws {
        let fix = try makeCoreFixture(testName: "SummaryTabTests")
        defer { fix.cleanup() }

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: UUID()
        )
        #expect(viewModel.selectedTab == .summary)
    }
}

// MARK: - Summary state from detail

@Suite("Summary tab -- state loaded from detail")
struct SummaryTabStateTests {
    @Test("load populates summaryText and editedSummary from detail")
    @MainActor
    func loadPopulatesSummaryState() async throws {
        let fix = try makeCoreFixture(testName: "SummaryTabTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Summary Test"
        )
        try await fix.store.applyGeneratedSummary(
            "# Meeting Notes\nGood meeting.", for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(viewModel.summaryText == "# Meeting Notes\nGood meeting.")
        #expect(viewModel.editedSummary == false)
    }

    @Test("load sets editedSummary true when user has edited")
    @MainActor
    func loadSetsEditedSummary() async throws {
        let fix = try makeCoreFixture(testName: "SummaryTabTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Edited Test"
        )
        try await fix.store.setSummary(
            "User edited summary", for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(viewModel.summaryText == "User edited summary")
        #expect(viewModel.editedSummary == true)
    }

    @Test("load reads aiAnalysisEnabled from settings")
    @MainActor
    func loadReadsAIAnalysisEnabled() async throws {
        let fix = try makeCoreFixture(testName: "SummaryTabTests")
        defer { fix.cleanup() }

        // Disable AI analysis in settings
        try await fix.store.updateSettings { settings in
            settings.aiAnalysisEnabled = false
        }

        let meetingID = try await fix.store.createMeeting(
            title: "Settings Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(viewModel.aiAnalysisEnabled == false)
    }
}

// MARK: - Empty states

@Suite("Summary tab -- empty state gating")
struct SummaryTabEmptyStateTests {
    @Test("empty summary with no transcript shows no-transcript state")
    @MainActor
    func emptyNoTranscript() async throws {
        let fix = try makeCoreFixture(testName: "SummaryTabTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "No Transcript"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(viewModel.summaryText.isEmpty)
        #expect(viewModel.displayedTranscript == nil)
    }

    @Test("empty summary with model available and feature on shows generate state")
    @MainActor
    func emptyModelAvailableFeatureOn() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "SummaryTabTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let result = FakeTranscriber.defaultResult
        let transcriptID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(
            transcriptID, for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(viewModel.summaryText.isEmpty)
        #expect(viewModel.displayedTranscript != nil)
        #expect(viewModel.modelAvailable == true)
        #expect(viewModel.aiAnalysisEnabled == true)
    }

    @Test("empty summary without model shows settings hint state")
    @MainActor
    func emptyNoModel() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: false,
            testName: "SummaryTabTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let result = FakeTranscriber.defaultResult
        let transcriptID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(
            transcriptID, for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(viewModel.summaryText.isEmpty)
        #expect(viewModel.displayedTranscript != nil)
        #expect(viewModel.modelAvailable == false)
    }

    @Test("empty summary with feature off shows settings hint state")
    @MainActor
    func emptyFeatureOff() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "SummaryTabTests"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings { settings in
            settings.aiAnalysisEnabled = false
        }

        let meetingID = try await fix.createMeetingWithAudio()
        let result = FakeTranscriber.defaultResult
        let transcriptID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(
            transcriptID, for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(viewModel.summaryText.isEmpty)
        #expect(viewModel.modelAvailable == true)
        #expect(viewModel.aiAnalysisEnabled == false)
    }
}

// MARK: - Streaming state

@Suite("Summary tab -- streaming display")
struct SummaryTabStreamingTests {
    @Test("streamingSummary reflects Intelligence streaming state")
    @MainActor
    func streamingSummaryFromIntelligence() async throws {
        let fix = try makeCoreFixture(testName: "SummaryTabTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Streaming Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // No streaming initially
        #expect(viewModel.streamingSummary == nil)

        // Simulate streaming
        fix.intelligence.streamingSummary[meetingID] = "# Partial"
        #expect(viewModel.streamingSummary == "# Partial")

        // Clear streaming
        fix.intelligence.streamingSummary.removeValue(forKey: meetingID)
        #expect(viewModel.streamingSummary == nil)
    }
}

// MARK: - Regenerate gating

@Suite("Summary tab -- regenerate via summary prompt sheet")
struct SummaryTabRegenerateTests {
    @Test("presentResummarizeSheet opens the sheet")
    @MainActor
    func presentResummarizeSheetOpensSheet() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "SummaryTabTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let result = FakeTranscriber.defaultResult
        let transcriptID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(
            transcriptID, for: meetingID
        )
        try await fix.store.setSummary(
            "User summary", for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(viewModel.editedSummary == true)
        #expect(viewModel.showResummarizeSheet == false)

        viewModel.presentResummarizeSheet()

        // Allow the async Task inside presentResummarizeSheet to complete
        try await Task.sleep(for: .milliseconds(50))

        #expect(viewModel.showResummarizeSheet == true)
        #expect(viewModel.summaryPromptModel != nil)
    }

    @Test("generateSummary runs directly for first-run Generate button")
    @MainActor
    func generateSummaryRunsDirectly() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "SummaryTabTests"
        )
        defer { fix.cleanup() }

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
            "AI summary", for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(viewModel.editedSummary == false)
        viewModel.generateSummary()

        // Should NOT open the sheet
        #expect(viewModel.showResummarizeSheet == false)
        // Should have switched to summary tab
        #expect(viewModel.selectedTab == .summary)
    }

    @Test("canRegenerateSummary requires transcript and model")
    @MainActor
    func canRegenerateGating() async throws {
        // No model, no transcript
        let fix = try makeCoreFixture(
            modelDownloaded: false,
            testName: "SummaryTabTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Gating Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(viewModel.canRegenerateSummary == false)

        // With model, still no transcript
        try await fix.fakeModelProvider.download(
            #require(LLMModelCatalog.all.first?.id),
            progress: { _, _ in }
        )
        await fix.modelManager.refresh()

        #expect(viewModel.modelAvailable == true)
        #expect(viewModel.canRegenerateSummary == false)
    }

    @Test("canRegenerateSummary true when transcript and model present")
    @MainActor
    func canRegenerateTrue() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "SummaryTabTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let result = FakeTranscriber.defaultResult
        let transcriptID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(
            transcriptID, for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(viewModel.canRegenerateSummary == true)
    }
}

// MARK: - Enhancement status pill

@Suite("Summary tab -- enhancement status pill")
struct SummaryTabPillTests {
    @Test("isEnhancing is true during identifyingSpeakers and summarizing")
    @MainActor
    func isEnhancingStates() async throws {
        let fix = try makeCoreFixture(testName: "SummaryTabTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Pill Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Initially not enhancing
        #expect(viewModel.isEnhancing == false)
        #expect(viewModel.enhancementStatus == nil)

        // preparing
        fix.intelligence.jobs[meetingID] = .preparing
        #expect(viewModel.isEnhancing == true)
        #expect(viewModel.enhancementStatus == .preparing)

        // identifyingSpeakers
        fix.intelligence.jobs[meetingID] = .identifyingSpeakers
        #expect(viewModel.isEnhancing == true)
        #expect(viewModel.enhancementStatus == .identifyingSpeakers)

        // summarizing
        fix.intelligence.jobs[meetingID] = .summarizing
        #expect(viewModel.isEnhancing == true)
        #expect(viewModel.enhancementStatus == .summarizing)

        // completed
        fix.intelligence.jobs[meetingID] = .completed
        #expect(viewModel.isEnhancing == false)

        // failed
        fix.intelligence.jobs[meetingID] = .failed(message: "err")
        #expect(viewModel.isEnhancing == false)

        // cleared
        fix.intelligence.jobs.removeValue(forKey: meetingID)
        #expect(viewModel.isEnhancing == false)
    }
}

// MARK: - In-flight generating state

@Suite("Summary tab -- in-flight generating routes through editor")
struct SummaryTabInFlightGeneratingTests {
    @Test("summarizing status with empty summary shows editor (not Generate button)")
    @MainActor
    func summarizingStatusShowsEditor() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "SummaryTabTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let result = FakeTranscriber.defaultResult
        let transcriptID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(
            transcriptID, for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Initially: empty summary, has transcript, model available
        #expect(viewModel.summaryText.isEmpty)
        #expect(viewModel.displayedTranscript != nil)
        #expect(viewModel.modelAvailable == true)

        // Set .summarizing (as generateSummary does synchronously)
        fix.intelligence.jobs[meetingID] = .summarizing

        // The view should now route through the editor branch (not
        // the Generate button). We verify this by checking that
        // enhancementStatus == .summarizing is true and the view's
        // condition for the unified editor branch is satisfied:
        // streamingSummary != nil || enhancementStatus == .summarizing || !summaryText.isEmpty
        let inEditor = viewModel.streamingSummary != nil
            || viewModel.enhancementStatus == .summarizing
            || !viewModel.summaryText.isEmpty
        #expect(inEditor == true)

        // And the pipeline is NOT shown (summarizing uses the editor)
        // pipelineStages is non-nil because .summarizing is active,
        // but the view checks the editor condition first
        #expect(viewModel.enhancementStatus == .summarizing)
    }

    @Test("preparing status with empty summary shows pipeline (not Generate button)")
    @MainActor
    func preparingStatusShowsPipeline() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "SummaryTabTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let result = FakeTranscriber.defaultResult
        let transcriptID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(
            transcriptID, for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Set .preparing (as runAutoEnhancements does synchronously)
        fix.intelligence.jobs[meetingID] = .preparing

        // The view should NOT show the editor (streaming is nil,
        // status is .preparing not .summarizing, summaryText is empty)
        let inEditor = viewModel.streamingSummary != nil
            || viewModel.enhancementStatus == .summarizing
            || !viewModel.summaryText.isEmpty
        #expect(inEditor == false)

        // Pipeline should be shown (non-nil stages)
        #expect(viewModel.pipelineStages != nil)
    }
}

// MARK: - Copy summary

@Suite("Summary tab -- copy")
struct SummaryTabCopyTests {
    @Test("copySummary copies markdown source to pasteboard")
    @MainActor
    func copySummaryText() async throws {
        let fix = try makeCoreFixture(testName: "SummaryTabTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Copy Test"
        )
        try await fix.store.applyGeneratedSummary(
            "# Summary\nAction items here", for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        viewModel.copySummary()

        let pasteboard = NSPasteboard.general
        let copied = pasteboard.string(forType: .string)
        #expect(copied == "# Summary\nAction items here")
    }

    @Test("copySummary is no-op when summary is empty")
    @MainActor
    func copySummaryEmptyNoOp() async throws {
        let fix = try makeCoreFixture(testName: "SummaryTabTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Empty Copy"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Set pasteboard to known value
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("sentinel", forType: .string)

        viewModel.copySummary()

        // Should not have changed
        #expect(pasteboard.string(forType: .string) == "sentinel")
    }
}

// MARK: - Summary autosave

@Suite("Summary tab -- autosave debounce")
struct SummaryTabAutosaveTests {
    @Test("updateSummary sets summaryText immediately")
    @MainActor
    func updateSummaryImmediate() async throws {
        let fix = try makeCoreFixture(testName: "SummaryTabTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Autosave Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        viewModel.updateSummary("New summary text")
        #expect(viewModel.summaryText == "New summary text")
    }

    @Test("flushPendingEdits also flushes summary to store")
    @MainActor
    func flushIncludesSummary() async throws {
        let fix = try makeCoreFixture(testName: "SummaryTabTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Flush Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Directly set summaryText (simulating user edit)
        viewModel.updateSummary("Flushed summary")

        // Flush should persist
        await viewModel.flushPendingEdits()

        // Verify it was saved
        let detail = try await fix.store.meetingDetail(id: meetingID)
        #expect(detail?.summary == "Flushed summary")
        #expect(detail?.editedSummary == true)
    }

    @Test("User clearing summary to empty persists with editedSummary")
    @MainActor
    func clearToEmptyPersists() async throws {
        let fix = try makeCoreFixture(testName: "SummaryTabTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Clear Test"
        )
        // Seed a non-empty summary via applyGeneratedSummary
        try await fix.store.applyGeneratedSummary(
            "Existing summary", for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()
        #expect(viewModel.summaryText == "Existing summary")
        #expect(viewModel.editedSummary == false)

        // User clears the summary to empty
        viewModel.updateSummary("")

        // Flush should persist the empty string
        await viewModel.flushPendingEdits()

        let detail = try await fix.store.meetingDetail(id: meetingID)
        #expect(detail?.summary == "")
        #expect(detail?.editedSummary == true)
    }
}

// MARK: - Enhancement completion reload

@Suite("Summary tab -- enhancement completion")
struct SummaryTabEnhancementCompletionTests {
    @Test("onEnhancementStatusChange reloads on completed")
    @MainActor
    func reloadsOnCompleted() async throws {
        let fix = try makeCoreFixture(testName: "SummaryTabTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Reload Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Apply a summary behind the scenes (as if Intelligence did)
        try await fix.store.applyGeneratedSummary(
            "AI generated notes", for: meetingID
        )

        // Trigger the enhancement completion handler
        await viewModel.onEnhancementStatusChange(.completed)

        // VM should have reloaded and picked up the new summary
        #expect(viewModel.summaryText == "AI generated notes")
        #expect(viewModel.editedSummary == false)
    }

    @Test("completion reload does not flip isLoading (scroll preservation)")
    @MainActor
    func completionReloadDoesNotFlipIsLoading() async throws {
        let fix = try makeCoreFixture(testName: "SummaryTabTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Scroll Fix"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // After initial load, isLoading must be false
        #expect(viewModel.isLoading == false)

        // Persist a summary behind the scenes (as if the Summarizer did)
        try await fix.store.applyGeneratedSummary(
            "Streamed summary", for: meetingID
        )

        // Trigger the enhancement completion handler
        await viewModel.onEnhancementStatusChange(.completed)

        // isLoading must remain false throughout -- toggling it would
        // tear down and recreate the entire view hierarchy (ScrollView
        // + MarkdownEditor), resetting scroll to top.
        #expect(viewModel.isLoading == false)

        // Data must still have been refreshed (proving refreshData()
        // ran, not a no-op skip)
        #expect(viewModel.summaryText == "Streamed summary")
        #expect(viewModel.editedSummary == false)
    }

    @Test("Reload after enhancement drops stale user edit and does not mark editedSummary")
    @MainActor
    func reloadDropsStaleDirtyEdit() async throws {
        let fix = try makeCoreFixture(testName: "SummaryTabTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Stale Edit Race"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // 1. User starts editing (sets summaryDirty, starts debounce)
        viewModel.updateSummary("my in-progress edits")

        // 2. AI enhancement completes: writes a generated summary
        //    to the store, then triggers onEnhancementStatusChange
        //    which calls load().
        try await fix.store.applyGeneratedSummary(
            "AI-generated summary", for: meetingID
        )
        // load() must cancel the stale debounce and reset dirty flag
        await viewModel.onEnhancementStatusChange(.completed)

        // 3. The VM should show the AI summary, NOT the stale edit
        #expect(viewModel.summaryText == "AI-generated summary")
        #expect(viewModel.editedSummary == false)

        // 4. Even after flushing, the store should still reflect
        //    the AI summary with editedSummary == false (the stale
        //    debounce was cancelled, so setSummary was never called).
        await viewModel.flushPendingEdits()
        let detail = try await fix.store.meetingDetail(id: meetingID)
        #expect(detail?.summary == "AI-generated summary")
        #expect(detail?.editedSummary == false)
    }

    @Test("onEnhancementStatusChange does not reload on non-completed")
    @MainActor
    func doesNotReloadOnNonCompleted() async throws {
        let fix = try makeCoreFixture(testName: "SummaryTabTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "No Reload Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Apply a summary behind the scenes
        try await fix.store.applyGeneratedSummary(
            "Should not appear yet", for: meetingID
        )

        // Non-completed statuses should not reload
        await viewModel.onEnhancementStatusChange(.preparing)
        #expect(viewModel.summaryText.isEmpty)

        await viewModel.onEnhancementStatusChange(.summarizing)
        #expect(viewModel.summaryText.isEmpty)

        await viewModel.onEnhancementStatusChange(.identifyingSpeakers)
        #expect(viewModel.summaryText.isEmpty)

        await viewModel.onEnhancementStatusChange(
            .failed(message: "err")
        )
        #expect(viewModel.summaryText.isEmpty)
    }
}

// MARK: - Open Settings

@Suite("Summary tab -- Open Settings navigation")
struct SummaryTabSettingsTests {
    @Test("openSettings routes to settings")
    @MainActor
    func openSettingsRoutes() async throws {
        let fix = try makeCoreFixture(testName: "SummaryTabTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Settings Nav"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        viewModel.openSettings()
        #expect(fix.core.route == .settings)
    }
}

// MARK: - Phase 8: Streaming→final flash & scroll (§13.2)

@Suite("Summary tab -- streaming→final flash prevention (§13.2)")
struct SummaryStreamingCompletionTests {
    @Test("summaryText seeded from last streamed value on completion")
    @MainActor
    func summaryTextSeededFromStreamingOnCompletion() async throws {
        let fix = try makeCoreFixture(testName: "SummaryTabTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Flash Prevention"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Simulate streaming updates
        fix.intelligence.streamingSummary[meetingID] = "# Partial"
        viewModel.onStreamingSummaryChange(
            oldValue: nil, newValue: "# Partial"
        )
        #expect(viewModel.streamingSummary == "# Partial")

        fix.intelligence.streamingSummary[meetingID] = "# Final Summary"
        viewModel.onStreamingSummaryChange(
            oldValue: "# Partial", newValue: "# Final Summary"
        )

        // Intelligence persists the summary, then clears streaming
        // and sets .completed on the same MainActor pass
        try await fix.store.applyGeneratedSummary(
            "# Final Summary", for: meetingID
        )
        fix.intelligence.streamingSummary.removeValue(forKey: meetingID)

        // Simulate the onChange firing with the old value
        viewModel.onStreamingSummaryChange(
            oldValue: "# Final Summary", newValue: nil
        )

        // Before load() runs, summaryText should be empty (not yet loaded)
        #expect(viewModel.summaryText.isEmpty)

        // Now the enhancement completion handler runs
        await viewModel.onEnhancementStatusChange(.completed)

        // summaryText must be populated -- never empty between
        // streaming clearing and load() completing
        #expect(viewModel.summaryText == "# Final Summary")
        #expect(viewModel.editedSummary == false)
    }

    @Test("summaryText not clobbered when no streaming on completion")
    @MainActor
    func summaryTextNotOverwrittenWhenNoStreaming() async throws {
        let fix = try makeCoreFixture(testName: "SummaryTabTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "No Streaming"
        )
        // Pre-populate a user-edited summary
        try await fix.store.setSummary(
            "User summary", for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(viewModel.summaryText == "User summary")
        #expect(viewModel.editedSummary == true)

        // Speaker-ID only completion (no streaming summary was produced)
        await viewModel.onEnhancementStatusChange(.completed)

        // summaryText must still be the user's text
        #expect(viewModel.summaryText == "User summary")
        #expect(viewModel.editedSummary == true)
    }

    @Test("onStreamingSummaryChange captures latest value through full cycle")
    @MainActor
    func streamingChangeTracking() async throws {
        let fix = try makeCoreFixture(testName: "SummaryTabTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Tracking Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Simulate progressive streaming updates
        viewModel.onStreamingSummaryChange(
            oldValue: nil, newValue: "# First"
        )
        viewModel.onStreamingSummaryChange(
            oldValue: "# First", newValue: "# Second"
        )

        // Streaming cleared: oldValue holds the final text
        viewModel.onStreamingSummaryChange(
            oldValue: "# Second", newValue: nil
        )

        // Persist the summary so load() finds it
        try await fix.store.applyGeneratedSummary(
            "# Second", for: meetingID
        )

        // The completion handler seeds summaryText from the captured
        // last-streamed value, then load() confirms it from the store
        await viewModel.onEnhancementStatusChange(.completed)
        #expect(viewModel.summaryText == "# Second")
    }

    @Test("onStreamingSummaryChange ignores empty strings")
    @MainActor
    func streamingChangeIgnoresEmpty() throws {
        let fix = try makeCoreFixture(testName: "SummaryTabTests")
        defer { fix.cleanup() }

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: UUID()
        )

        // Empty new value should not be tracked
        viewModel.onStreamingSummaryChange(
            oldValue: nil, newValue: ""
        )

        // Empty old value on clear should not be tracked
        viewModel.onStreamingSummaryChange(
            oldValue: "", newValue: nil
        )

        // summaryText should still be empty after completion
        // (no streamed value was captured)
        // Since we can't read lastStreamedSummary directly,
        // we verify that summaryText stays empty
        #expect(viewModel.summaryText.isEmpty)
    }

    @Test("completion path never transits empty state after non-empty streaming")
    @MainActor
    func completionNeverTransitsEmpty() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "SummaryTabTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let result = FakeTranscriber.defaultResult
        let transcriptID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(
            transcriptID, for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Verify initial state: empty summary, has transcript
        #expect(viewModel.summaryText.isEmpty)
        #expect(viewModel.displayedTranscript != nil)

        // Simulate the full streaming→completion cycle
        fix.intelligence.streamingSummary[meetingID] = "# Generated"
        viewModel.onStreamingSummaryChange(
            oldValue: nil, newValue: "# Generated"
        )

        // Persist the summary
        try await fix.store.applyGeneratedSummary(
            "# Generated", for: meetingID
        )

        // Intelligence clears streaming
        fix.intelligence.streamingSummary.removeValue(forKey: meetingID)
        viewModel.onStreamingSummaryChange(
            oldValue: "# Generated", newValue: nil
        )

        // At this point: streamingSummary is nil, summaryText is still
        // empty (load hasn't run). The view state machine would show
        // the empty/Generate state WITHOUT the flash fix.

        // Enhancement completes
        await viewModel.onEnhancementStatusChange(.completed)

        // summaryText must be populated -- the empty state was never
        // reached because onEnhancementStatusChange seeded it
        #expect(viewModel.summaryText == "# Generated")
        #expect(viewModel.editedSummary == false)

        // And streamingSummary is nil (no longer streaming)
        #expect(viewModel.streamingSummary == nil)
    }

    @Test("onStreamingSummaryChange seeds summaryText synchronously when completed")
    @MainActor
    func streamingClearSeedsSummaryTextOnCompleted() async throws {
        let fix = try makeCoreFixture(testName: "SummaryTabTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Sync Seed Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Verify summaryText starts empty
        #expect(viewModel.summaryText.isEmpty)

        // Intelligence sets .completed BEFORE clearing streamingSummary,
        // so enhancementStatus is already .completed when onChange fires.
        fix.intelligence.jobs[meetingID] = .completed

        // Simulate the streaming-cleared onChange
        viewModel.onStreamingSummaryChange(
            oldValue: "Final summary", newValue: nil
        )

        // summaryText must be seeded synchronously (no await needed)
        #expect(viewModel.summaryText == "Final summary")
    }

    @Test("onStreamingSummaryChange does NOT seed summaryText when failed")
    @MainActor
    func streamingClearDoesNotSeedOnFailure() async throws {
        let fix = try makeCoreFixture(testName: "SummaryTabTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Fail No Seed Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(viewModel.summaryText.isEmpty)

        // Enhancement failed (not completed)
        fix.intelligence.jobs[meetingID] = .failed(message: "err")

        // Simulate the streaming-cleared onChange
        viewModel.onStreamingSummaryChange(
            oldValue: "partial text", newValue: nil
        )

        // summaryText must NOT be seeded -- partial content should not
        // be shown for a failed run
        #expect(viewModel.summaryText.isEmpty)
    }
}

// MARK: - Regenerate instant-clear (isSummaryRegenerating)

@Suite("Summary tab -- regenerate instant-clear")
struct SummaryTabRegenerateInstantClearTests {
    @Test("isSummaryRegenerating true at .preparing during manual regenerate")
    @MainActor
    func trueAtPreparingDuringRegenerate() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "SummaryTabTests"
        )
        defer { fix.cleanup() }

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
            "Old summary", for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(!viewModel.summaryText.isEmpty)
        #expect(viewModel.isSummaryRegenerating == false)

        // Simulate: user clicks Regenerate -> runSummary sets flag
        viewModel.generateSummary()

        // Intelligence sets .preparing synchronously
        fix.intelligence.jobs[meetingID] = .preparing

        #expect(viewModel.summaryRegenRequested == true)
        #expect(viewModel.isSummaryRegenerating == true)
    }

    @Test("isSummaryRegenerating true at .identifyingSpeakers during manual regenerate")
    @MainActor
    func trueAtIdentifyingSpeakers() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "SummaryTabTests"
        )
        defer { fix.cleanup() }

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
            "Old summary", for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        viewModel.generateSummary()
        fix.intelligence.jobs[meetingID] = .identifyingSpeakers

        #expect(viewModel.isSummaryRegenerating == true)
    }

    @Test("isSummaryRegenerating false once .summarizing begins")
    @MainActor
    func falseOnceSummarizingBegins() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "SummaryTabTests"
        )
        defer { fix.cleanup() }

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
            "Old summary", for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        viewModel.generateSummary()
        fix.intelligence.jobs[meetingID] = .summarizing

        // Once .summarizing, the editor branch handles display
        #expect(viewModel.isSummaryRegenerating == false)
    }

    @Test("summaryRegenRequested reset on .completed")
    @MainActor
    func flagResetOnCompleted() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "SummaryTabTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Regen Complete"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Simulate the flag being set (as runSummary does synchronously)
        // without spawning the actual analysis Task.
        viewModel.summaryRegenRequested = true
        fix.intelligence.jobs[meetingID] = .preparing
        #expect(viewModel.summaryRegenRequested == true)

        fix.intelligence.jobs[meetingID] = .completed
        await viewModel.onEnhancementStatusChange(.completed)
        #expect(viewModel.summaryRegenRequested == false)
        #expect(viewModel.isSummaryRegenerating == false)
    }

    @Test("summaryRegenRequested reset on .failed")
    @MainActor
    func flagResetOnFailed() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "SummaryTabTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Regen Failed"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        viewModel.summaryRegenRequested = true
        fix.intelligence.jobs[meetingID] = .preparing
        #expect(viewModel.summaryRegenRequested == true)

        fix.intelligence.jobs[meetingID] = .failed(message: "err")
        await viewModel.onEnhancementStatusChange(
            .failed(message: "err")
        )
        #expect(viewModel.summaryRegenRequested == false)
    }

    @Test("summaryRegenRequested reset on nil (cancelled)")
    @MainActor
    func flagResetOnNil() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "SummaryTabTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Regen Cancelled"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        viewModel.summaryRegenRequested = true
        fix.intelligence.jobs[meetingID] = .preparing
        #expect(viewModel.summaryRegenRequested == true)

        fix.intelligence.jobs.removeValue(forKey: meetingID)
        await viewModel.onEnhancementStatusChange(nil)
        #expect(viewModel.summaryRegenRequested == false)
    }
}

// MARK: - Regenerate instant-clear (view branch + auto-run)

@Suite("Summary tab -- regenerate instant-clear view integration")
struct SummaryTabRegenerateViewIntegrationTests {
    @Test("auto-run path: hasPendingSummaryStage drives isSummaryRegenerating")
    @MainActor
    func autoRunPathUsesPendingStage() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "SummaryTabTests"
        )
        defer { fix.cleanup() }

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
            "Old summary", for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Auto-run: no manual request, but pipeline is active with
        // a pending Summarizing stage (identifyingSpeakers status)
        #expect(viewModel.summaryRegenRequested == false)
        fix.intelligence.jobs[meetingID] = .identifyingSpeakers

        // hasPendingSummaryStage should be true (Summarizing is pending)
        #expect(viewModel.hasPendingSummaryStage == true)
        #expect(viewModel.isSummaryRegenerating == true)
    }

    @Test("view condition: stale summary yields to pipeline while regenerating")
    @MainActor
    func viewBranchYieldsToPipeline() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "SummaryTabTests"
        )
        defer { fix.cleanup() }

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
            "Old summary", for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(!viewModel.summaryText.isEmpty)

        // Simulate regenerate during .identifyingSpeakers
        viewModel.generateSummary()
        fix.intelligence.jobs[meetingID] = .identifyingSpeakers

        // The view's editor branch condition should be FALSE (stale
        // summary suppressed) so the pipeline branch is reached:
        let editorBranch = viewModel.streamingSummary != nil
            || viewModel.enhancementStatus == .summarizing
            || (!viewModel.summaryText.isEmpty
                && !viewModel.isSummaryRegenerating)
        #expect(editorBranch == false)

        // Pipeline stages should be available
        #expect(viewModel.pipelineStages != nil)
    }

    @Test("isSummaryRegenerating false when not enhancing")
    @MainActor
    func falseWhenNotEnhancing() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "SummaryTabTests"
        )
        defer { fix.cleanup() }

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
            "Old summary", for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // No enhancement active -- even with summaryText, should not
        // be regenerating
        #expect(viewModel.isSummaryRegenerating == false)
    }

    @Test("isSummaryRegenerating false when streaming is active")
    @MainActor
    func falseWhenStreamingActive() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "SummaryTabTests"
        )
        defer { fix.cleanup() }

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
            "Old summary", for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        viewModel.generateSummary()
        fix.intelligence.jobs[meetingID] = .summarizing
        fix.intelligence.streamingSummary[meetingID] = "# Partial"

        // Streaming is active, so isSummaryRegenerating should be false
        // (the editor branch handles the display)
        #expect(viewModel.isSummaryRegenerating == false)
    }
}
