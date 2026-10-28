import BiscottiTestSupport
import DataStore
import Foundation
import LiveTranscriptionService
import LiveTranscriptModel
import Testing
import Transcription
import TranscriptionService
@testable import AppCore

private let row = LiveRow(track: .mic, startTime: 0, endTime: 1, settledText: "Hello", tailText: " wor")

@MainActor
private struct LiveCoreFixture {
    let fix: CoreFixture
    let engines = FakeLiveEngineFactory(finish: .hang)
    let live: LiveTranscriptionService

    /// The fake recorder never closes its tap, so a finish after Stop always
    /// runs into the stop deadline, kept short here.
    init(
        isEnabled: Bool = true,
        model: FakeLiveModel = FakeLiveModel(),
        languageSwitchTimeout: Duration = .seconds(3),
        workerStuckDecode: Duration = .seconds(10)
    ) throws {
        live = makeFakeLiveService(
            engines: engines,
            model: model,
            isEnabled: isEnabled,
            timing: LiveTiming(
                publishInterval: .zero,
                stopDeadline: .milliseconds(300),
                pumpInterval: .milliseconds(5),
                finishMargin: .milliseconds(50),
                languageSwitchTimeout: languageSwitchTimeout,
                workerStuckDecode: workerStuckDecode
            )
        )
        fix = try makeCoreFixture(liveTranscription: live, testName: "AppCoreLiveTests")
    }

    var core: AppCore {
        fix.core
    }

    /// Starts a recording whose audio files exist, so its final pass completes.
    func startRecordingWithAudio() async throws -> UUID {
        await core.startRecording()
        let meetingID = try #require(core.recording.state.meetingID)
        let folder = fix.storageRoot.appendingPathComponent(meetingID.uuidString)
        for name in ["mic.aac", "system.aac"] {
            try Data([0]).write(to: folder.appendingPathComponent(name))
        }
        return meetingID
    }

    func runningEngine() async throws -> FakeLiveEngine {
        try await waitUntil("a live engine") { engines.engines.count == 1 }
        let engine = engines.engines[0]
        try await waitUntil("its config") { await engine.config != nil }
        return engine
    }
}

@Suite("AppCore -- live transcription")
@MainActor
struct AppCoreLiveTests {
    @Test("A recording gets a live tap and a live session, and holds the final-pass queue")
    func startRecordingPassesTapStartsLiveAndHoldsTheQueue() async throws {
        let ctx = try LiveCoreFixture()
        defer { ctx.fix.cleanup() }
        await ctx.core.startRecording()

        #expect(ctx.fix.fakeRecorder.backing.liveTap != nil)
        _ = try await ctx.runningEngine()
        #expect(ctx.live.status == .starting)
        let meetingID = try #require(ctx.core.recording.state.meetingID)
        let earlier = try await ctx.fix.createMeetingWithAudio()
        let pass = Task { await ctx.core.transcription.transcribe(meetingID: earlier) }
        try await waitUntil("the held pass") { ctx.core.transcription.jobs[earlier] == .queued(.waitingForRecording) }
        _ = await ctx.core.stopRecording()
        await pass.value
        await ctx.core.awaitPendingTranscription()
        #expect(ctx.core.transcription.jobs[meetingID] != nil)
    }

    @Test("Capture starts before the live session makes its engine")
    func startRecordingStartsCaptureBeforeLiveSession() async throws {
        let engines = FakeLiveEngineFactory()
        let probe = CaptureOrderProbe()
        let live = LiveTranscriptionService(
            engine: {
                probe.engineMade()
                return engines.make()
            },
            model: FakeLiveModel(),
            vocabulary: { _ in [] },
            isEnabled: true,
            power: FakePowerSource(),
            defaults: nil,
            timing: LiveTiming(publishInterval: .zero, stopDeadline: .milliseconds(200), pumpInterval: .milliseconds(5), finishMargin: .milliseconds(50))
        )
        let fix = try makeCoreFixture(liveTranscription: live, testName: "AppCoreLiveTests")
        defer { fix.cleanup() }
        probe.recorder = fix.fakeRecorder.backing

        await fix.core.startRecording()
        try await waitUntil("the engine") { probe.captureStartedFirst != nil }
        #expect(probe.captureStartedFirst == true)
        _ = await fix.core.stopRecording()
        await fix.core.awaitPendingTranscription()
    }

    @Test("Stop publishes the draft, and the final pass starts only after the live finish")
    func stopRecordingFinishesLiveThenQueuesFinalPass() async throws {
        let ctx = try LiveCoreFixture()
        defer { ctx.fix.cleanup() }
        let meetingID = try await ctx.startRecordingWithAudio()
        let engine = try await ctx.runningEngine()
        await engine.emit(liveUpdate(.mic, rows: [row], transcribedThrough: 1, settledThrough: 0.5))
        try await waitUntil("the live row") { !ctx.live.rows.isEmpty }

        _ = try #require(await ctx.core.stopRecording())
        #expect(ctx.live.draft(for: meetingID)?.rows == [row], "the draft exists when the meeting opens")
        #expect(!ctx.fix.fakeEngine.backing.processAudioCalled, "the final pass waits for the live finish")
        #expect(ctx.core.transcription.jobs[meetingID] == .queued(.waitingForTurn), "its transcript reads as coming")

        await ctx.core.awaitPendingTranscription()
        #expect(await engine.isCancelled, "the finish ran out of time and was cancelled")
        #expect(ctx.fix.fakeEngine.backing.shutdownCallCount >= 1, "a timed-out finish releases the queue's worker")
        #expect(ctx.fix.fakeEngine.backing.processAudioCalled)
        #expect(ctx.core.transcription.jobs[meetingID] == .completed)
        #expect(ctx.live.draft(for: meetingID) == nil, "the saved transcript replaced the draft")
    }

    /// Keeps the live model loaded in the queue's worker, as on a Mac with
    /// more than 8 GiB: that connection keeps the worker alive.
    private func keepLiveModelLoaded(_ ctx: LiveCoreFixture) async throws {
        ctx.core.transcription.keepModelLoaded("live-model")
        try await waitUntil("the kept model's load") { ctx.fix.fakeEngine.backing.keptLoaded == ["live-model"] }
        try await waitUntil("its end") { !ctx.core.transcription.isPreparingModels }
    }

    @Test("A held decode, the kept-model connection, a language switch and Stop: the final pass still runs, on a fresh worker")
    func stopDuringAStuckLanguageSwitchStillRunsTheFinalPass() async throws {
        // The old engine's finish never returns, as when a decode is stuck in the worker.
        let ctx = try LiveCoreFixture(languageSwitchTimeout: .seconds(30))
        defer { ctx.fix.cleanup() }
        try await keepLiveModelLoaded(ctx)
        let meetingID = try await ctx.startRecordingWithAudio()
        let engine = try await ctx.runningEngine()
        await engine.emit(liveUpdate(.mic, rows: [row], transcribedThrough: 1, settledThrough: 0.5))
        try await waitUntil("the live row") { !ctx.live.rows.isEmpty }
        let switching = Task { await ctx.live.setLanguage(.detect) }
        try await waitUntil("the old engine's finish") { await engine.isFinishing }
        let shutdownsBefore = ctx.fix.fakeEngine.backing.shutdownCallCount

        _ = try #require(await ctx.core.stopRecording())
        await switching.value
        await ctx.core.awaitPendingTranscription()

        #expect(await engine.isCancelled)
        let shutdownsAtThePass = try #require(ctx.fix.fakeEngine.backing.shutdownCountAtProcessAudio)
        #expect(shutdownsAtThePass > shutdownsBefore, "the kept-model connection closes before the pass, so the pass gets a fresh worker")
        #expect(ctx.core.transcription.jobs[meetingID] == .completed)
        #expect(ctx.engines.engines.count == 1, "no engine starts after Stop")
    }

    @Test("A language switch whose old engine never finishes closes the kept-model connection and goes on with a new engine")
    func stuckLanguageSwitchResetsTheWorker() async throws {
        let ctx = try LiveCoreFixture(languageSwitchTimeout: .milliseconds(50), workerStuckDecode: .milliseconds(50))
        defer { ctx.fix.cleanup() }
        try await keepLiveModelLoaded(ctx)
        _ = try await ctx.startRecordingWithAudio()
        let engine = try await ctx.runningEngine()
        let shutdownsBefore = ctx.fix.fakeEngine.backing.shutdownCallCount

        await ctx.live.setLanguage(.detect)

        #expect(await engine.isCancelled)
        #expect(ctx.fix.fakeEngine.backing.shutdownCallCount > shutdownsBefore)
        try await waitUntil("the new engine") { ctx.engines.engines.count == 2 }
        _ = await ctx.core.stopRecording()
        await ctx.core.awaitPendingTranscription()
    }

    @Test("A failed final pass keeps the draft until the meeting is deleted")
    func failedFinalPassKeepsDraft() async throws {
        let ctx = try LiveCoreFixture()
        defer { ctx.fix.cleanup() }
        // No audio files: the pass fails.
        await ctx.core.startRecording()
        let engine = try await ctx.runningEngine()
        await engine.emit(liveUpdate(.mic, rows: [row], transcribedThrough: 1, settledThrough: 0.5))
        try await waitUntil("the live row") { !ctx.live.rows.isEmpty }

        let meetingID = try #require(await ctx.core.stopRecording())
        await ctx.core.awaitPendingTranscription()
        #expect(ctx.core.transcription.jobs[meetingID] == .failed(message: "No audio files available for this meeting.", retriable: false))
        #expect(ctx.live.draft(for: meetingID)?.rows.map(\.settledText) == ["Hello"])

        await ctx.core.deleteMeeting(meetingID: meetingID)
        #expect(ctx.live.draft(for: meetingID) == nil)
    }

    @Test("The live transcript setting turns live transcription on and off during a recording")
    func settingChangeMidRecordingStartsOrStopsLive() async throws {
        let ctx = try LiveCoreFixture(isEnabled: false)
        defer { ctx.fix.cleanup() }
        try await ctx.fix.store.updateSettings { $0.liveTranscriptEnabled = false }
        await ctx.core.onLaunch()
        await ctx.core.startRecording()
        #expect(ctx.live.status == .off)
        #expect(ctx.engines.engines.isEmpty)

        try await ctx.fix.store.updateSettings { $0.liveTranscriptEnabled = true }
        NotificationCenter.default.post(name: .liveTranscriptEnabledDidChange, object: nil)
        let engine = try await ctx.runningEngine()
        #expect(ctx.live.isEnabled)
        #expect(ctx.live.startMarker != nil)

        try await ctx.fix.store.updateSettings { $0.liveTranscriptEnabled = false }
        NotificationCenter.default.post(name: .liveTranscriptEnabledDidChange, object: nil)
        try await waitUntil("live transcription off") { !ctx.live.isEnabled }
        #expect(ctx.live.status == .off)
        #expect(await engine.isCancelled)
        #expect(ctx.core.recording.state.isRecording, "recording continues")
        _ = await ctx.core.stopRecording()
        await ctx.core.awaitPendingTranscription()
    }
}

@Suite("AppCore -- model preparation")
@MainActor
struct AppCorePreparationTests {
    private let liveModel = LiveTranscriptionDefaults.whisperModel
    private let finalModel = TranscriptionMethod.current.whisperModel

    private nonisolated static let roomy: UInt64 = 16 << 30
    private nonisolated static let small: UInt64 = 8 << 30

    private func launch(_ ctx: LiveCoreFixture, liveEnabled: Bool, memory: UInt64 = roomy) async throws {
        ctx.core.physicalMemory = memory
        try await ctx.fix.store.updateSettings {
            $0.onboardingComplete = true
            $0.liveTranscriptEnabled = liveEnabled
        }
        await ctx.core.onLaunch()
    }

    @Test("Launch loads the live model in a run of its own, then prepares the final pass's model", arguments: [roomy, small])
    func launchPreparesPresentModels(memory: UInt64) async throws {
        let ctx = try LiveCoreFixture()
        defer { ctx.fix.cleanup() }
        try await launch(ctx, liveEnabled: true, memory: memory)

        // Above 8 GiB the live model is kept loaded, also while the final
        // pass's model is prepared.
        let kept = memory == Self.roomy
        try await waitUntil("the preparations") { ctx.fix.fakeEngine.backing.preparationRequests.count >= 2 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(ctx.fix.fakeEngine.backing.preparationRequests == [[liveModel], [finalModel]])
        #expect(ctx.fix.fakeEngine.backing.keptLoaded == [kept ? liveModel : nil, nil])
    }

    @Test("Macs with more than 8 GiB keep the live model loaded")
    func keepsLiveModelLoadedAboveEightGiB() {
        #expect(!AppCore.keepsLiveModelLoaded(physicalMemory: 8 << 30))
        #expect(AppCore.keepsLiveModelLoaded(physicalMemory: 16 << 30))
    }

    @Test("Launch leaves out the live model while live transcription is off, and models not downloaded")
    func launchLeavesOutModelsItCannotUse() async throws {
        let ctx = try LiveCoreFixture(isEnabled: false)
        defer { ctx.fix.cleanup() }
        try await launch(ctx, liveEnabled: false)
        try await waitUntil("the preparation") { !ctx.fix.fakeEngine.backing.preparationRequests.isEmpty }
        #expect(ctx.fix.fakeEngine.backing.preparationRequests == [[finalModel]])

        let missing = try LiveCoreFixture(model: FakeLiveModel(present: false))
        defer { missing.fix.cleanup() }
        missing.fix.fakeEngine.backing.modelsPresentResult = false
        try await launch(missing, liveEnabled: true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(missing.fix.fakeEngine.backing.preparationRequests.isEmpty)
    }

    @Test("A finished live model download prepares the model; a second download loads the new files again", arguments: [roomy, small])
    func liveModelDownloadPreparesIt(memory: UInt64) async throws {
        let ctx = try LiveCoreFixture(model: FakeLiveModel(present: false))
        defer { ctx.fix.cleanup() }
        ctx.core.physicalMemory = memory
        ctx.fix.fakeEngine.backing.modelsPresentResult = false

        await ctx.live.downloadModel()
        try await waitUntil("the preparation") { ctx.fix.fakeEngine.backing.preparationRequests.count == 1 }
        #expect(ctx.fix.fakeEngine.backing.preparationRequests == [[liveModel]])

        await ctx.live.downloadModel()
        try await waitUntil("the second preparation") { ctx.fix.fakeEngine.backing.preparationRequests.count == 2 }
        #expect(ctx.fix.fakeEngine.backing.preparationRequests == [[liveModel], [liveModel]])
        // A kept model is loaded again even though the worker holds it.
        let kept = memory == Self.roomy
        #expect(ctx.fix.fakeEngine.backing.keptLoaded == [kept ? liveModel : nil, kept ? liveModel : nil])
        #expect(ctx.fix.fakeEngine.backing.reloadedKept == [false, kept])
    }

    @Test("Turning the live transcript on prepares its model; models already prepared are not prepared again")
    func enablingLivePreparesItsModel() async throws {
        let ctx = try LiveCoreFixture(isEnabled: false)
        defer { ctx.fix.cleanup() }
        try await launch(ctx, liveEnabled: false)
        try await waitUntil("the first preparation") { ctx.fix.fakeEngine.backing.preparationRequests.count == 1 }

        try await ctx.fix.store.updateSettings { $0.liveTranscriptEnabled = true }
        NotificationCenter.default.post(name: .liveTranscriptEnabledDidChange, object: nil)

        try await waitUntil("the live model's preparation") { ctx.fix.fakeEngine.backing.preparationRequests.count == 2 }
        #expect(ctx.fix.fakeEngine.backing.preparationRequests == [[finalModel], [liveModel]])
    }
}

/// Records whether capture had started when the live engine was made.
private final class CaptureOrderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var backing: FakeRecorder.Backing?
    private var startedFirst: Bool?

    var recorder: FakeRecorder.Backing? {
        get { lock.withLock { backing } }
        set { lock.withLock { backing = newValue } }
    }

    var captureStartedFirst: Bool? {
        lock.withLock { startedFirst }
    }

    func engineMade() {
        lock.withLock {
            if startedFirst == nil { startedFirst = backing?.startCalled ?? false }
        }
    }
}
