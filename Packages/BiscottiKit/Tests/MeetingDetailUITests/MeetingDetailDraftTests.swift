import BiscottiTestSupport
import DataStore
import Foundation
import LiveTranscriptionService
import LiveTranscriptModel
import Testing
import Transcription
import TranscriptUI
@testable import AppCore
@testable import MeetingDetailUI

/// Drafts each test sets, read through `source`.
@MainActor
final class FakeLiveDrafts {
    var drafts: [UUID: LiveTranscriptSnapshot] = [:]

    var source: LiveDraftSource {
        LiveDraftSource(draft: { [self] in drafts[$0] })
    }
}

private func draftSnapshot(_ rows: [LiveRow]) -> LiveTranscriptSnapshot {
    LiveTranscriptSnapshot(
        sessionID: UUID(),
        revision: rows.count,
        captureWatermark: 10,
        transcribedThrough: 10,
        settledThrough: 8,
        rows: rows,
        gaps: [],
        includesTail: true
    )
}

private let othersRow = LiveRow(track: .system, startTime: 0, endTime: 4, settledText: "Okay, so the beta build", tailText: "")
private let youRow = LiveRow(track: .mic, startTime: 4, endTime: 7, settledText: "Do we have the fix", tailText: " from Fri")

@Suite("MeetingDetailViewModel -- live draft and swap")
@MainActor
struct MeetingDetailDraftTests {
    private struct Context {
        let fix: CoreFixture
        let drafts: FakeLiveDrafts
        let meetingID: UUID
        let viewModel: MeetingDetailViewModel
    }

    private func makeContext(draft: LiveTranscriptSnapshot? = draftSnapshot([othersRow, youRow])) async throws -> Context {
        let fix = try makeCoreFixture(testName: "MeetingDetailUITests")
        let drafts = FakeLiveDrafts()
        let meetingID = try await fix.createMeetingWithAudio()
        drafts.drafts[meetingID] = draft
        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID, liveDrafts: drafts.source)
        return Context(fix: fix, drafts: drafts, meetingID: meetingID, viewModel: viewModel)
    }

    /// Saves the final transcript, releases the draft as AppCore does, and
    /// reports the completed job to the view model.
    private func completeFinalPass(_ context: Context) async throws {
        let transcriptID = try await context.fix.store.addTranscript(
            FakeTranscriber.defaultResult,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: context.meetingID
        )
        try await context.fix.store.setPreferredTranscript(transcriptID, for: context.meetingID)
        context.drafts.drafts[context.meetingID] = nil
        context.fix.core.transcription.jobs[context.meetingID] = .completed
        await context.viewModel.onJobStatusChange(.completed)
    }

    @Test("shows the draft with You and Others labels while the final pass runs")
    func showsDraftWhileFinalPassRuns() async throws {
        let context = try await makeContext()
        defer { context.fix.cleanup() }
        context.fix.core.transcription.jobs[context.meetingID] = .transcribing

        await context.viewModel.load()

        guard case let .draft(snapshot, status) = context.viewModel.displayState else {
            Issue.record("Expected a draft, got \(context.viewModel.displayState)")
            return
        }
        #expect(status == .finalPassInProgress)
        #expect(snapshot.rows.map(\.id) == [othersRow.id, youRow.id])
        let bubbles = context.viewModel.bubbleListItems.compactMap(\.bubble)
        #expect(bubbles.map(\.label?.name) == ["Others", "You"])
        #expect(bubbles.map(\.side) == [.leading, .trailing])

        // The live engine's last words join the draft.
        var finished = youRow
        finished.settledText = "Do we have the fix from Friday?"
        finished.tailText = ""
        context.drafts.drafts[context.meetingID] = draftSnapshot([othersRow, finished])
        context.viewModel.syncDraft()

        #expect(context.viewModel.bubbleListItems.compactMap(\.bubble).last?.settledText == "Do we have the fix from Friday?")
    }

    @Test("swaps to the final transcript when it is saved")
    func swapsToFinalWhenSaved() async throws {
        let context = try await makeContext()
        defer { context.fix.cleanup() }
        context.fix.core.transcription.jobs[context.meetingID] = .transcribing
        await context.viewModel.load()

        try await completeFinalPass(context)

        guard case .transcript = context.viewModel.displayState else {
            Issue.record("Expected the final transcript, got \(context.viewModel.displayState)")
            return
        }
        #expect(context.viewModel.shownDraft == nil)
        #expect(context.viewModel.bubbleListItems.compactMap(\.bubble).map(\.settledText)
            == ["Hello, how are you?", "I'm doing well, thanks."])
    }

    @Test("the swap waits while the list has focus")
    func swapWaitsWhileTheListHasFocus() async throws {
        let context = try await makeContext()
        defer { context.fix.cleanup() }
        context.fix.core.transcription.jobs[context.meetingID] = .transcribing
        await context.viewModel.load()
        context.viewModel.setTranscriptListFocused(true)

        try await completeFinalPass(context)

        guard case let .draft(_, status) = context.viewModel.displayState else {
            Issue.record("Expected the draft to stay, got \(context.viewModel.displayState)")
            return
        }
        #expect(status == .finalTranscriptReady)

        context.viewModel.setTranscriptListFocused(false)

        guard case .transcript = context.viewModel.displayState else {
            Issue.record("Expected the swap after focus left, got \(context.viewModel.displayState)")
            return
        }
    }

    @Test("the final transcript is saved and loaded before the visible swap")
    func finalIsSavedBeforeTheVisibleSwap() async throws {
        let context = try await makeContext()
        defer { context.fix.cleanup() }
        context.fix.core.transcription.jobs[context.meetingID] = .transcribing
        await context.viewModel.load()
        context.viewModel.setTranscriptListFocused(true)

        try await completeFinalPass(context)

        let stored = try await context.fix.store.meetingDetail(id: context.meetingID)
        #expect(stored?.preferredTranscript != nil)
        #expect(context.viewModel.detail?.preferredTranscript != nil)
        #expect(context.viewModel.shownDraft != nil)
    }

    @Test("the swap reveals the time that was at the top of the draft")
    func swapRevealsTheAnchorTime() async throws {
        let context = try await makeContext()
        defer { context.fix.cleanup() }
        context.fix.core.transcription.jobs[context.meetingID] = .transcribing
        await context.viewModel.load()
        context.viewModel.selectedTab = .transcript
        context.viewModel.setTranscriptListFocused(true)
        context.viewModel.draftAnchorTime = 4

        try await completeFinalPass(context)
        #expect(context.viewModel.transcriptRevealTime == nil)

        // Leaving the tab removes the list, so the swap happens.
        context.viewModel.selectedTab = .summary
        context.viewModel.transcriptTabSelectionChanged()

        #expect(context.viewModel.shownDraft == nil)
        #expect(context.viewModel.transcriptRevealTime == 4)
        #expect(context.viewModel.draftAnchorTime == nil)
    }

    @Test("Copy copies the draft on screen until the swap, then the final transcript")
    func copyCopiesTheDraftUntilTheSwap() async throws {
        let context = try await makeContext()
        defer { context.fix.cleanup() }
        context.fix.core.transcription.jobs[context.meetingID] = .transcribing
        await context.viewModel.load()
        context.viewModel.setTranscriptListFocused(true)

        #expect(context.viewModel.hasCopyableTranscript)
        let draftText = "Others: Okay, so the beta build\nYou: Do we have the fix from Fri"
        #expect(context.viewModel.transcriptCopyText == draftText)

        try await completeFinalPass(context)
        // Held by the selection: still the draft on screen and on the pasteboard.
        #expect(context.viewModel.transcriptCopyText == draftText)

        context.viewModel.setTranscriptListFocused(false)
        #expect(context.viewModel.transcriptCopyText?.hasPrefix("[0:00] Speaker 0") == true)
    }

    @Test("an empty draft has nothing to copy")
    func emptyDraftHasNothingToCopy() async throws {
        let context = try await makeContext(draft: draftSnapshot([]))
        defer { context.fix.cleanup() }

        await context.viewModel.load()

        #expect(!context.viewModel.hasCopyableTranscript)
        #expect(context.viewModel.transcriptCopyText == nil)
    }

    @Test("a draft waiting for a recording says so")
    func waitingStatusWhileRecording() async throws {
        let context = try await makeContext()
        defer { context.fix.cleanup() }
        context.fix.core.transcription.jobs[context.meetingID] = .queued(.waitingForRecording)

        await context.viewModel.load()

        guard case let .draft(_, status) = context.viewModel.displayState else {
            Issue.record("Expected a draft, got \(context.viewModel.displayState)")
            return
        }
        #expect(status == .waitingForRecording)
    }

    @Test("without a draft, a waiting meeting shows the waiting state")
    func waitingWithoutDraft() async throws {
        let context = try await makeContext(draft: nil)
        defer { context.fix.cleanup() }
        context.fix.core.transcription.jobs[context.meetingID] = .queued(.waitingForRecording)

        await context.viewModel.load()

        #expect(context.viewModel.displayState == .waitingForRecording)
        #expect(!context.viewModel.canReTranscribe)
    }

    @Test("a meeting waiting for another meeting's pass says it waits to transcribe")
    func queuedForTurnShowsWaitingToTranscribe() async throws {
        let context = try await makeContext(draft: nil)
        defer { context.fix.cleanup() }
        context.fix.core.transcription.jobs[context.meetingID] = .queued(.waitingForTurn)

        await context.viewModel.load()

        #expect(context.viewModel.displayState == .processing(message: "Waiting to transcribe\u{2026}"))
        #expect(!context.viewModel.canReTranscribe)
    }

    @Test("a draft waiting for another meeting's pass shows the final pass in progress")
    func draftQueuedForTurnShowsFinalPassInProgress() async throws {
        let context = try await makeContext()
        defer { context.fix.cleanup() }
        context.fix.core.transcription.jobs[context.meetingID] = .queued(.waitingForTurn)

        await context.viewModel.load()

        guard case let .draft(_, status) = context.viewModel.displayState else {
            Issue.record("Expected a draft, got \(context.viewModel.displayState)")
            return
        }
        #expect(status == .finalPassInProgress)
    }

    @Test("a failed final pass keeps the draft with the error")
    func failedFinalPassKeepsDraft() async throws {
        let context = try await makeContext()
        defer { context.fix.cleanup() }
        context.fix.core.transcription.jobs[context.meetingID] = .failed(message: "Worker stopped.", retriable: true)

        await context.viewModel.load()

        guard case let .draft(_, status) = context.viewModel.displayState else {
            Issue.record("Expected a draft, got \(context.viewModel.displayState)")
            return
        }
        #expect(status == .finalPassFailed(message: "Worker stopped.", retriable: true))
    }

    @Test("a speaker tagged as the current user sits on the You side")
    func savedTranscriptUsesCurrentUserSide() async throws {
        let context = try await makeContext(draft: nil)
        defer { context.fix.cleanup() }
        let store = context.fix.store
        let transcriptID = try await store.addTranscript(
            FakeTranscriber.defaultResult,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: context.meetingID
        )
        try await store.setPreferredTranscript(transcriptID, for: context.meetingID)
        let myself = try await store.findOrCreatePerson(name: "Stephen", email: "me@example.com")
        try await store.setSnapshot(CalendarSnapshot(compositeKey: "standup", title: "Standup"), for: context.meetingID)
        try await store.setParticipants([myself], organizer: myself, currentUser: myself, for: context.meetingID)
        try await store.setSpeakerAssignment(speakerID: 1, personID: myself, for: transcriptID)

        await context.viewModel.load()

        let bubbles = context.viewModel.bubbleListItems.compactMap(\.bubble)
        #expect(bubbles.map(\.side) == [.leading, .trailing])
        #expect(bubbles.map(\.label?.name) == ["Speaker 0", "You"])
        #expect(bubbles[1].speakerID == 1)
    }

    @Test("with no live source, a saved transcript shows as before")
    func noLiveSourceShowsSavedTranscript() async throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailUITests")
        defer { fix.cleanup() }
        let meetingID = try await fix.createMeetingWithAudio()
        let transcriptID = try await fix.store.addTranscript(
            FakeTranscriber.defaultResult,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        try await fix.store.setPreferredTranscript(transcriptID, for: meetingID)
        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)

        await viewModel.load()

        guard case .transcript = viewModel.displayState else {
            Issue.record("Expected the transcript, got \(viewModel.displayState)")
            return
        }
        let bubbles = viewModel.bubbleListItems.compactMap(\.bubble)
        #expect(bubbles.map(\.side) == [.leading, .leading])
        #expect(bubbles.map(\.label?.name) == ["Speaker 0", "Speaker 1"])
    }
}

@Suite("MeetingDetailViewModel -- live draft source")
@MainActor
struct MeetingDetailLiveDraftSourceTests {
    @Test("by default the view model reads the live service, and a completed pass releases its draft")
    func defaultSourceReadsTheLiveService() async throws {
        let engines = FakeLiveEngineFactory()
        let live = makeFakeLiveService(engines: engines)
        let fix = try makeCoreFixture(liveTranscription: live, testName: "MeetingDetailUITests")
        defer { fix.cleanup() }
        let meetingID = try await fix.createMeetingWithAudio()
        let tap = ScriptedTap()
        await live.start(meetingID: meetingID, tap: tap, timelineOffset: 0)
        try await waitUntil("a live engine") { engines.engines.count == 1 }
        let engine = engines.engines[0]
        try await waitUntil("its config") { await engine.config != nil }
        await engine.emit(liveUpdate(.mic, rows: [youRow], transcribedThrough: 7, settledThrough: 6))
        try await waitUntil("the live row") { !live.rows.isEmpty }
        let finishing = live.stop(meetingID)

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        fix.core.transcription.jobs[meetingID] = .transcribing
        await viewModel.load()
        guard case let .draft(snapshot, _) = viewModel.displayState else {
            Issue.record("Expected a draft, got \(viewModel.displayState)")
            return
        }
        #expect(snapshot.rows == [youRow])

        let transcriptID = try await fix.store.addTranscript(FakeTranscriber.defaultResult, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID)
        try await fix.store.setPreferredTranscript(transcriptID, for: meetingID)
        fix.core.transcription.jobs[meetingID] = .completed
        await viewModel.onJobStatusChange(.completed)
        #expect(live.draft(for: meetingID) == nil)
        tap.end(at: 7)
        _ = await finishing.value
    }
}
