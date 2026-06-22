import AppKit
import BiscottiTestSupport
import DataStore
import Foundation
import Intelligence
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

    @Test("load reads summarizeEnabled from settings")
    @MainActor
    func loadReadsSummarizeEnabled() async throws {
        let fix = try makeCoreFixture(testName: "SummaryTabTests")
        defer { fix.cleanup() }

        // Disable summarize in settings
        try await fix.store.updateSettings { settings in
            settings.summarizeTranscripts = false
        }

        let meetingID = try await fix.store.createMeeting(
            title: "Settings Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(viewModel.summarizeEnabled == false)
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
        #expect(viewModel.summarizeEnabled == true)
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
            settings.summarizeTranscripts = false
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
        #expect(viewModel.summarizeEnabled == false)
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

@Suite("Summary tab -- regenerate confirmation gating")
struct SummaryTabRegenerateTests {
    @Test("generateSummary shows confirmation when editedSummary is true")
    @MainActor
    func regenerateConfirmWhenEdited() async throws {
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
        #expect(viewModel.showRegenerateConfirm == false)

        viewModel.generateSummary()

        #expect(viewModel.showRegenerateConfirm == true)
    }

    @Test("generateSummary runs directly when editedSummary is false")
    @MainActor
    func regenerateNoConfirmWhenNotEdited() async throws {
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

        // Should NOT show the confirmation dialog
        #expect(viewModel.showRegenerateConfirm == false)
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
        fix.fakeModelProvider.downloaded = true
        fix.intelligence.refreshModelState()

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
}
