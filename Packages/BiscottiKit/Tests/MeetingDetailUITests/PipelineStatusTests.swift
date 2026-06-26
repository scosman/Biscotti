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

    @Test("pipelineStages omits AI stages when aiAnalysisEnabled is off")
    @MainActor
    func omitsAIStagesWhenOff() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings { settings in
            settings.aiAnalysisEnabled = false
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
        #expect(stages.count == 1)
        #expect(stages[0].label == "Transcribing")
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

    @Test("pipelineStages shows speakers + hides summary when editedSummary + AI on")
    @MainActor
    func showsSpeakersHidesSummaryWhenEdited() async throws {
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

        // AI is on (default), model available, but summary is edited
        #expect(viewModel.aiAnalysisEnabled == true)

        fix.core.transcription.jobs[meetingID] = .transcribing

        let stages = try #require(viewModel.pipelineStages)
        #expect(stages.count == 2)
        #expect(stages[0].label == "Transcribing")
        #expect(stages[1].label == "Inferring participant names")
        // "Summarizing" is omitted because editedSummary is true
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

        // Transcription completed with AI on + model available: handoff
        // state keeps the pipeline active while enhancement starts up.
        fix.core.transcription.jobs[meetingID] = .completed
        #expect(viewModel.isPipelineActive == true)

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

// MARK: - Handoff gap (Issue 1: no spinner between transcribe and enhance)

@Suite("Pipeline status -- transcription-to-enhancement handoff")
struct PipelineHandoffTests {
    @Test("pipeline stays visible during handoff gap (transcription completed, enhancement not started)")
    @MainActor
    func handoffGapShowsPipeline() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Handoff Gap"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Simulate the gap: transcription completed, no enhancement yet
        fix.core.transcription.jobs[meetingID] = .completed
        // enhStatus is nil -- the gap state

        let stages = try #require(viewModel.pipelineStages)
        #expect(stages.count == 3)
        #expect(stages[0] == PipelineStage(
            label: "Transcribing", state: .done
        ))
        // Speaker inference shows as active during handoff
        #expect(stages[1] == PipelineStage(
            label: "Inferring participant names", state: .active
        ))
        #expect(stages[2] == PipelineStage(
            label: "Summarizing", state: .pending
        ))
    }

    @Test("handoff gap not triggered when AI analysis is disabled")
    @MainActor
    func handoffGapNotShownWhenAIOff() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        try await fix.store.updateSettings { settings in
            settings.aiAnalysisEnabled = false
        }

        let meetingID = try await fix.store.createMeeting(
            title: "Handoff AI Off"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        fix.core.transcription.jobs[meetingID] = .completed

        // No pipeline visible because AI is off
        #expect(viewModel.pipelineStages == nil)
    }

    @Test("handoff gap not triggered when no model available")
    @MainActor
    func handoffGapNotShownWhenNoModel() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: false,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Handoff No Model"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        fix.core.transcription.jobs[meetingID] = .completed

        // No pipeline visible because no model
        #expect(viewModel.pipelineStages == nil)
    }

    @Test("handoff gap clears when enhancement starts")
    @MainActor
    func handoffGapClearsOnEnhancementStart() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Handoff Clear"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Start in handoff gap
        fix.core.transcription.jobs[meetingID] = .completed
        #expect(viewModel.pipelineStages != nil)

        // Enhancement starts -- handoff gap ends, normal pipeline takes over
        fix.intelligence.jobs[meetingID] = .preparing
        let stages = try #require(viewModel.pipelineStages)
        #expect(stages[1] == PipelineStage(
            label: "Inferring participant names", state: .pending
        ))
    }

    @Test("handoff gap omits Summarizing when editedSummary is true")
    @MainActor
    func handoffGapOmitsSummarizingWhenEdited() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Handoff Edited"
        )
        // Mark summary as user-edited
        try await fix.store.setSummary(
            "User edited", for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Handoff gap with editedSummary: should show 2 stages only
        fix.core.transcription.jobs[meetingID] = .completed

        let stages = try #require(viewModel.pipelineStages)
        #expect(stages.count == 2)
        #expect(stages[0] == PipelineStage(
            label: "Transcribing", state: .done
        ))
        #expect(stages[1] == PipelineStage(
            label: "Inferring participant names", state: .active
        ))
    }

    @Test("isPipelineActive is true during handoff gap")
    @MainActor
    func isPipelineActiveDuringHandoff() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Active Handoff"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        fix.core.transcription.jobs[meetingID] = .completed

        #expect(viewModel.isPipelineActive == true)
    }
}

// MARK: - Regenerate shows all stages (Issue 2: missing Summarizing stage)

@Suite("Pipeline status -- regenerate shows Summarizing stage")
struct PipelineRegenerateStagesTests {
    @Test("regenerate shows Summarizing stage even when editedSummary is true")
    @MainActor
    func regenerateShowsSummarizingWhenEdited() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Regen Stages"
        )
        // Mark summary as user-edited
        try await fix.store.setSummary(
            "User edited", for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Without regeneration: pipeline omits Summarizing when edited
        fix.intelligence.jobs[meetingID] = .preparing
        var stages = try #require(viewModel.pipelineStages)
        #expect(stages.count == 2) // Transcribing + Inferring only

        // Set summaryRegenRequested (as runSummary does)
        viewModel.summaryRegenRequested = true

        // Now the pipeline should show all 3 stages
        stages = try #require(viewModel.pipelineStages)
        #expect(stages.count == 3)
        #expect(stages[0].label == "Transcribing")
        #expect(stages[1].label == "Inferring participant names")
        #expect(stages[2].label == "Summarizing")
        #expect(stages[2].state == .pending)
    }

    @Test("regenerate pipeline shows Summarizing through full lifecycle")
    @MainActor
    func regenerateFullLifecycle() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Regen Lifecycle"
        )
        try await fix.store.setSummary(
            "User edited", for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // Simulate regenerate request
        viewModel.summaryRegenRequested = true
        fix.intelligence.jobs[meetingID] = .preparing

        // Phase 0: Preparing -- all 3 stages
        var stages = try #require(viewModel.pipelineStages)
        #expect(stages.count == 3)
        #expect(stages[0].state == .done) // Transcribing
        #expect(stages[1].state == .pending) // Inferring
        #expect(stages[2].state == .pending) // Summarizing

        // Phase 1: Speaker ID running
        fix.intelligence.jobs[meetingID] = .identifyingSpeakers
        stages = try #require(viewModel.pipelineStages)
        #expect(stages.count == 3)
        #expect(stages[1].state == .active) // Inferring
        #expect(stages[2].state == .pending) // Summarizing

        // Phase 2: Summarizing
        fix.intelligence.jobs[meetingID] = .summarizing
        stages = try #require(viewModel.pipelineStages)
        #expect(stages.count == 3)
        #expect(stages[1].state == .done) // Inferring
        #expect(stages[2].state == .active) // Summarizing

        // Phase 3: Completed
        fix.intelligence.jobs[meetingID] = .completed
        #expect(viewModel.pipelineStages == nil)
    }

    @Test("summaryRegenRequested resets on completion")
    @MainActor
    func summaryRegenRequestedResetsOnCompletion() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Regen Reset"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        viewModel.summaryRegenRequested = true
        #expect(viewModel.summaryRegenRequested == true)

        // Completion resets the flag
        await viewModel.onEnhancementStatusChange(.completed)
        #expect(viewModel.summaryRegenRequested == false)
    }

    @Test("summaryRegenRequested resets on failure")
    @MainActor
    func summaryRegenRequestedResetsOnFailed() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "PipelineStatusTests"
        )
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Regen Failed Reset"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        viewModel.summaryRegenRequested = true
        fix.intelligence.jobs[meetingID] = .preparing
        #expect(viewModel.summaryRegenRequested == true)

        // Failure resets the flag so the pipeline doesn't stick
        await viewModel.onEnhancementStatusChange(
            .failed(message: "model error")
        )
        #expect(viewModel.summaryRegenRequested == false)
    }
}

// MARK: - Settings loading

@Suite("Pipeline status -- settings loading")
struct PipelineSettingsTests {
    @Test("load reads aiAnalysisEnabled from settings")
    @MainActor
    func loadReadsAIAnalysisEnabled() async throws {
        let fix = try makeCoreFixture(testName: "PipelineStatusTests")
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

    @Test("load defaults aiAnalysisEnabled to true")
    @MainActor
    func defaultAIAnalysisEnabledTrue() async throws {
        let fix = try makeCoreFixture(testName: "PipelineStatusTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Default Test"
        )
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(viewModel.aiAnalysisEnabled == true)
    }
}
