import BiscottiTestSupport
import DataStore
import Foundation
import Intelligence
import Testing
import Transcription
import TranscriptionService
@testable import AppCore
@testable import MeetingDetailUI

// MARK: - Pipeline stage model

@Suite("Pipeline status -- stage model basics")
struct PipelineStageModelTests {
    @Test("pipelineStages is nil when no jobs are active")
    @MainActor
    func noActiveJobs() async throws {
        let fix = try makeCoreFixture(testName: "PipelineStatusTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Pipeline Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(viewModel.pipelineStages == nil)
    }

    @Test("pipelineStages shows only Transcribing when no model")
    @MainActor
    func transcribingOnlyNoModel() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: false,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Pipeline Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Simulate transcription in progress
        fix.core.transcription.jobs[meetingID] = .transcribing

        let stages = try #require(viewModel.pipelineStages)
        #expect(stages.count == 1)
        #expect(stages[0].label == "Transcribing")
        #expect(stages[0].state == .active)
    }

    @Test("pipelineStages shows all three stages when model + both toggles on")
    @MainActor
    func allThreeStages() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Pipeline Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Simulate transcription in progress
        fix.core.transcription.jobs[meetingID] = .transcribing

        let stages = try #require(viewModel.pipelineStages)
        #expect(stages.count == 3)
        #expect(stages[0] == PipelineStage(
            label: "Transcribing", state: .active
        ))
        #expect(stages[1] == PipelineStage(
            label: "Inferring participant names", state: .pending
        ))
        #expect(stages[2] == PipelineStage(
            label: "Summarizing", state: .pending
        ))
    }

    @Test("pipelineStages omits 'Inferring' when guessSpeakers is off")
    @MainActor
    func omitsSpeakersWhenOff() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings { settings in
            settings.guessSpeakerNames = false
        }

        let meetingID = try await fix.store.createMeeting(
            title: "Pipeline Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        fix.core.transcription.jobs[meetingID] = .transcribing

        let stages = try #require(viewModel.pipelineStages)
        #expect(stages.count == 2)
        #expect(stages[0].label == "Transcribing")
        #expect(stages[1].label == "Summarizing")
    }

    @Test("pipelineStages omits 'Summarizing' when editedSummary is true")
    @MainActor
    func omitsSummaryWhenEdited() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Pipeline Test"
        )
        // Mark summary as user-edited
        try await fix.store.setSummary(
            "User edited", for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        fix.core.transcription.jobs[meetingID] = .transcribing

        let stages = try #require(viewModel.pipelineStages)
        #expect(stages.count == 2)
        #expect(stages[0].label == "Transcribing")
        #expect(stages[1].label == "Inferring participant names")
        // "Summarizing" is omitted because editedSummary is true
    }

    @Test("pipelineStages omits 'Summarizing' when summarize toggle is off")
    @MainActor
    func omitsSummaryWhenToggleOff() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings { settings in
            settings.summarizeTranscripts = false
        }

        let meetingID = try await fix.store.createMeeting(
            title: "Pipeline Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        fix.core.transcription.jobs[meetingID] = .transcribing

        let stages = try #require(viewModel.pipelineStages)
        #expect(stages.count == 2)
        #expect(stages[0].label == "Transcribing")
        #expect(stages[1].label == "Inferring participant names")
    }
}

// MARK: - Pipeline stage transitions

@Suite("Pipeline status -- stage lifecycle transitions")
struct PipelineStageTransitionTests {
    @Test("stages transition through full lifecycle: transcribing -> speakers -> summarizing -> done")
    @MainActor
    func fullLifecycle() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Lifecycle"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Phase 1: Transcribing
        fix.core.transcription.jobs[meetingID] = .transcribing
        var stages = try #require(viewModel.pipelineStages)
        #expect(stages[0].state == .active) // Transcribing
        #expect(stages[1].state == .pending) // Inferring
        #expect(stages[2].state == .pending) // Summarizing

        // Phase 2: Transcription done, speaker ID starts
        fix.core.transcription.jobs[meetingID] = .completed
        fix.intelligence.jobs[meetingID] = .identifyingSpeakers
        stages = try #require(viewModel.pipelineStages)
        #expect(stages[0].state == .done) // Transcribing
        #expect(stages[1].state == .active) // Inferring
        #expect(stages[2].state == .pending) // Summarizing

        // Phase 3: Speaker ID done, summarizing starts
        fix.intelligence.jobs[meetingID] = .summarizing
        stages = try #require(viewModel.pipelineStages)
        #expect(stages[0].state == .done) // Transcribing
        #expect(stages[1].state == .done) // Inferring
        #expect(stages[2].state == .active) // Summarizing

        // Phase 4: All done
        fix.intelligence.jobs[meetingID] = .completed
        #expect(viewModel.pipelineStages == nil)
    }

    @Test("downloading model shows as active transcription stage")
    @MainActor
    func downloadingModelIsTranscribing() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Download"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        fix.core.transcription.jobs[meetingID] = .downloadingModel(
            message: "Downloading model..."
        )

        let stages = try #require(viewModel.pipelineStages)
        #expect(stages[0].label == "Transcribing")
        #expect(stages[0].state == .active)
    }

    @Test("pipeline replaces no-transcript placeholder")
    @MainActor
    func pipelineReplacesNoTranscript() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Replace Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Without pipeline: no transcript available
        #expect(viewModel.pipelineStages == nil)
        #expect(viewModel.displayedTranscript == nil)
        #expect(viewModel.summaryText.isEmpty)

        // With pipeline: stages should be returned
        fix.core.transcription.jobs[meetingID] = .transcribing
        #expect(viewModel.pipelineStages != nil)
    }
}

// MARK: - Enhancement pill removed

@Suite("Pipeline status -- pill removed")
struct PipelinePillRemovedTests {
    @Test("isEnhancing still reports correctly for Regenerate disable")
    @MainActor
    func isEnhancingStillWorks() async throws {
        let fix = try makeCoreFixture(testName: "PipelineStatusTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Pill Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // isEnhancing is still used for disabling Regenerate button
        #expect(viewModel.isEnhancing == false)
        fix.intelligence.jobs[meetingID] = .preparing
        #expect(viewModel.isEnhancing == true)
        fix.intelligence.jobs[meetingID] = .identifyingSpeakers
        #expect(viewModel.isEnhancing == true)
        fix.intelligence.jobs[meetingID] = .summarizing
        #expect(viewModel.isEnhancing == true)
        fix.intelligence.jobs[meetingID] = .completed
        #expect(viewModel.isEnhancing == false)
    }
}

// MARK: - Preparing status prevents Generate flash

@Suite("Pipeline status -- preparing prevents Generate flash")
struct PipelinePreparingTests {
    @Test("pipelineStages is non-nil during .preparing (no Generate gap)")
    @MainActor
    func preparingShowsPipeline() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Preparing Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Before: no pipeline
        #expect(viewModel.pipelineStages == nil)

        // Set .preparing (as runAutoEnhancements does synchronously)
        fix.intelligence.jobs[meetingID] = .preparing

        // Pipeline must be non-nil
        let stages = try #require(viewModel.pipelineStages)

        // Transcribing should be done (no transcription in progress)
        #expect(stages[0].label == "Transcribing")
        #expect(stages[0].state == .done)

        // Gated stages should be .pending during .preparing
        #expect(stages[1].label == "Inferring participant names")
        #expect(stages[1].state == .pending)
        #expect(stages[2].label == "Summarizing")
        #expect(stages[2].state == .pending)
    }

    @Test("isPipelineActive is true during .preparing")
    @MainActor
    func isPipelineActiveDuringPreparing() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Active Check"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(viewModel.isPipelineActive == false)

        fix.intelligence.jobs[meetingID] = .preparing
        #expect(viewModel.isPipelineActive == true)

        fix.intelligence.jobs[meetingID] = .completed
        #expect(viewModel.isPipelineActive == false)
    }

    @Test("full lifecycle with preparing: preparing -> speakers -> summarizing -> done")
    @MainActor
    func fullLifecycleWithPreparing() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Lifecycle"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Phase 0: Preparing (before model load)
        fix.intelligence.jobs[meetingID] = .preparing
        var stages = try #require(viewModel.pipelineStages)
        #expect(stages[0].state == .done) // Transcribing (not running)
        #expect(stages[1].state == .pending) // Inferring
        #expect(stages[2].state == .pending) // Summarizing

        // Phase 1: Speaker ID starts
        fix.intelligence.jobs[meetingID] = .identifyingSpeakers
        stages = try #require(viewModel.pipelineStages)
        #expect(stages[0].state == .done) // Transcribing
        #expect(stages[1].state == .active) // Inferring
        #expect(stages[2].state == .pending) // Summarizing

        // Phase 2: Summarizing starts
        fix.intelligence.jobs[meetingID] = .summarizing
        stages = try #require(viewModel.pipelineStages)
        #expect(stages[0].state == .done) // Transcribing
        #expect(stages[1].state == .done) // Inferring
        #expect(stages[2].state == .active) // Summarizing

        // Phase 3: All done
        fix.intelligence.jobs[meetingID] = .completed
        #expect(viewModel.pipelineStages == nil)
    }
}

// MARK: - Auto-jump

@Suite("Pipeline status -- auto-jump to Summary tab")
struct PipelineAutoJumpTests {
    @Test("auto-jump sets selectedTab to .summary when pipeline activates")
    @MainActor
    func autoJumpOnActivation() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "AutoJump"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Start on a different tab
        viewModel.selectedTab = .notes

        // Simulate pipeline becoming active
        viewModel.onPipelineActiveChange(true)

        #expect(viewModel.selectedTab == .summary)
    }

    @Test("auto-jump fires only once per pipeline activation")
    @MainActor
    func autoJumpOnceOnly() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "AutoJump Once"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // First activation: jumps to summary
        viewModel.selectedTab = .notes
        viewModel.onPipelineActiveChange(true)
        #expect(viewModel.selectedTab == .summary)

        // User switches to transcript manually
        viewModel.selectedTab = .transcript

        // Second call: should NOT override the user's tab choice
        viewModel.onPipelineActiveChange(true)
        #expect(viewModel.selectedTab == .transcript)
    }

    @Test("auto-jump resets after load so next pipeline activation can jump")
    @MainActor
    func autoJumpResetsOnLoad() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "AutoJump Reset"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // First activation: jumps
        viewModel.selectedTab = .notes
        viewModel.onPipelineActiveChange(true)
        #expect(viewModel.selectedTab == .summary)

        // Reload resets the flag
        await viewModel.load()

        // Second activation after reload: should jump again
        viewModel.selectedTab = .transcript
        viewModel.onPipelineActiveChange(true)
        #expect(viewModel.selectedTab == .summary)
    }

    @Test("isPipelineActive reflects pipeline state")
    @MainActor
    func isPipelineActiveProperty() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Active Check"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(viewModel.isPipelineActive == false)

        fix.core.transcription.jobs[meetingID] = .transcribing
        #expect(viewModel.isPipelineActive == true)

        fix.core.transcription.jobs[meetingID] = .completed
        #expect(viewModel.isPipelineActive == false)

        fix.intelligence.jobs[meetingID] = .identifyingSpeakers
        #expect(viewModel.isPipelineActive == true)

        fix.intelligence.jobs[meetingID] = .completed
        #expect(viewModel.isPipelineActive == false)
    }
}

// MARK: - Re-transcribe triggers auto-enhancements

@Suite("Pipeline status -- re-transcribe triggers auto-run")
struct PipelineReTranscribeTests {
    @Test("reTranscribe triggers runAutoEnhancements via LLM session")
    @MainActor
    func reTranscribeTriggersAutoRun() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        // Create meeting with audio so re-transcribe has something to work on
        let meetingID = try await fix.createMeetingWithAudio()
        let result = FakeTranscriber.defaultResult
        let txID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(
            txID, for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Before re-transcribe: no LLM sessions
        #expect(fix.fakeLLMRunner.sessionCount == 0)

        // Trigger re-transcribe which should also call runAutoEnhancements
        await viewModel.reTranscribe()

        // The LLM runner should have been called (proving auto-enhancements ran)
        #expect(fix.fakeLLMRunner.sessionCount == 1)
    }
}

// MARK: - Settings loading

@Suite("Pipeline status -- settings loading")
struct PipelineSettingsTests {
    @Test("load reads guessSpeakersEnabled from settings")
    @MainActor
    func loadReadsGuessSpeakers() async throws {
        let fix = try makeCoreFixture(testName: "PipelineStatusTests")
        defer { fix.cleanup() }

        // Disable guessSpeakerNames in settings
        try await fix.store.updateSettings { settings in
            settings.guessSpeakerNames = false
        }

        let meetingID = try await fix.store.createMeeting(
            title: "Settings Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(viewModel.guessSpeakersEnabled == false)
    }

    @Test("load defaults guessSpeakersEnabled to true")
    @MainActor
    func defaultGuessSpeakersTrue() async throws {
        let fix = try makeCoreFixture(testName: "PipelineStatusTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Default Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(viewModel.guessSpeakersEnabled == true)
    }
}
