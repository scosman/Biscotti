import BiscottiTestSupport
import Foundation
import LiveTranscriptModel
import Testing
import Transcription
@testable import LiveTranscriptionService

@MainActor
private struct LiveFixture {
    let engines: FakeLiveEngineFactory
    let model: FakeLiveModel
    let power: FakePowerSource
    let service: LiveTranscriptionService
    let tap = ScriptedTap()
    let meetingID = UUID()

    init(
        starts: [FakeLiveEngine.StartBehavior] = [],
        finish: FakeLiveEngine.FinishBehavior = .returns([]),
        isEnabled: Bool = true,
        modelPresent: Bool = true,
        vocabulary: @escaping @Sendable (UUID) async -> [String] = { _ in [] },
        macLanguageCode: String = "en",
        stopDeadline: Duration = .seconds(5),
        languageSwitchTimeout: Duration = .seconds(3),
        workerStuckDecode: Duration = .seconds(10)
    ) {
        engines = FakeLiveEngineFactory(starts: starts, finish: finish)
        model = FakeLiveModel(present: modelPresent)
        power = FakePowerSource()
        service = makeFakeLiveService(
            engines: engines,
            model: model,
            vocabulary: vocabulary,
            isEnabled: isEnabled,
            power: power,
            macLanguageCode: macLanguageCode,
            timing: LiveTiming(
                publishInterval: .zero,
                stopDeadline: stopDeadline,
                pumpInterval: .milliseconds(5),
                finishMargin: .milliseconds(100),
                languageSwitchTimeout: languageSwitchTimeout,
                workerStuckDecode: workerStuckDecode
            )
        )
    }

    func start(startedAt: Date = Date(), timelineOffset: TimeInterval = 0) async {
        await service.start(meetingID: meetingID, tap: tap, timelineOffset: timelineOffset, recordingStartedAt: startedAt)
    }

    /// The nth engine, once its start has its config.
    func engine(_ index: Int) async throws -> FakeLiveEngine {
        try await waitUntil("engine \(index)") { engines.engines.count > index }
        let engine = engines.engines[index]
        try await waitUntil("engine \(index)'s config") { await engine.config != nil }
        return engine
    }

    /// Starts, and returns the running engine with one row shown.
    func startWithRow(_ row: LiveRow, settledThrough: TimeInterval = 0) async throws -> FakeLiveEngine {
        await start()
        let engine = try await engine(0)
        await engine.emit(liveUpdate(.mic, rows: [row], transcribedThrough: row.endTime, settledThrough: settledThrough))
        try await waitUntil("the row") { !service.rows.isEmpty }
        return engine
    }
}

private let hello = LiveRow(track: .mic, startTime: 0, endTime: 1, settledText: "Hello", tailText: " wor")

/// Counts the worker resets a session asked for.
@MainActor
private final class ResetCounter {
    var calls = 0
}

/// Holds a start inside its vocabulary read until the test opens it.
private actor Gate {
    private var waiter: CheckedContinuation<Void, Never>?

    var isWaiting: Bool {
        waiter != nil
    }

    func wait() async {
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        waiter?.resume()
        waiter = nil
    }
}

@Suite("LiveTranscriptionService -- recording lifecycle")
@MainActor
struct LiveTranscriptionServiceTests {
    @Test("A start uses the Mac's language default, the meeting's vocabulary and the chosen engine")
    func startsWithResolvedLanguageAndVocabulary() async throws {
        let fix = LiveFixture(vocabulary: { _ in ["Biscotti"] })
        #expect(fix.service.canStartLive)
        await fix.start()
        #expect(fix.service.status == .starting)
        let config = try #require(await fix.engine(0).config)
        #expect(config.language == .english)
        #expect(config.vocabulary == ["Biscotti"])
        #expect(config.whisperModel == "openai_whisper-small")
        #expect(config.tracks == [.mic, .system])
        #expect(config.updateInterval == 1)
        #expect(config.generation == 1)

        try await fix.engine(0).emit(liveUpdate(.mic, rows: [hello], transcribedThrough: 1, settledThrough: 0.5))
        try await waitUntil("live") { fix.service.status == .live }
        #expect(fix.service.rows == [hello])

        let french = LiveFixture(macLanguageCode: "fr")
        await french.start()
        #expect(try await french.engine(0).config?.language == .detect)
        #expect(french.service.language == .detect)
    }

    @Test("Without the model the live transcript is unavailable and no engine starts")
    func missingModelIsUnavailable() async {
        let fix = LiveFixture(modelPresent: false)
        #expect(!fix.service.canStartLive)
        #expect(fix.service.modelState == .missing)
        await fix.start()
        #expect(fix.service.status == .unavailable(.modelMissing))
        #expect(fix.engines.engines.isEmpty)
    }

    @Test("A language the engine cannot transcribe is unavailable")
    func unsupportedLanguageIsUnavailable() async throws {
        let fix = LiveFixture()
        await fix.start()
        let engine = try await fix.engine(0)
        await fix.service.setLanguage(.locale("tlh"))
        #expect(fix.service.status == .unavailable(.languageUnsupported))
        #expect(await engine.isCancelled)
        await fix.service.setLanguage(.english)
        try await waitUntil("a new engine") { fix.engines.engines.count == 2 }
        #expect(fix.service.startMarker != nil)
    }

    @Test("A restarted engine first gets the audio the failed one took but never settled, so nothing is lost")
    func restartReplaysUnsettledAudio() async throws {
        let fix = LiveFixture()
        await fix.start()
        let first = try await fix.engine(0)
        fix.tap.mic.pushTone(seconds: 1, from: 0)
        try await waitUntil("four chunks") { await first.offered.count == 4 }

        await first.fail()
        let second = try await fix.engine(1)
        try await waitUntil("the unsettled chunks") { await second.offered.count == 4 }
        let chunks = await second.offered
        #expect(chunks.first?.startTime == 0)
        #expect(isContiguous(chunks))
        #expect(fix.service.gaps.isEmpty)
    }

    @Test("A rebuilt replay is in time order from the settled time, without repeats")
    func replayChunksAreOrderedFromTheSettledTime() {
        func chunk(_ start: TimeInterval) -> LiveAudioChunk {
            LiveAudioChunk(track: .mic, startTime: start, samples: Array(repeating: 0.1, count: 4000))
        }
        let replay = LiveRecordingSession.replayChunks([chunk(1), chunk(0.5), chunk(0.75), chunk(0.5), chunk(0.25)], from: 0.4)
        #expect(replay.map(\.startTime) == [0.4, 0.5, 0.75, 1])
    }

    @Test("A replayed chunk starts at the track's settled time")
    func replayChunkStartsAtTheSettledTime() throws {
        let chunk = LiveAudioChunk(track: .mic, startTime: 0.25, samples: Array(repeating: 0.1, count: 4000))
        let trimmed = try #require(LiveRecordingSession.replayChunk(chunk, from: 0.4))
        #expect(abs(trimmed.startTime - 0.4) < 1e-9 && trimmed.samples.count == 1600)
        #expect(LiveRecordingSession.replayChunk(chunk, from: 0) == chunk)
        #expect(LiveRecordingSession.replayChunk(chunk, from: 0.5) == nil)
    }

    @Test("A failed engine restarts once and the new engine first gets what it never settled; a second failure stops live transcription")
    func restartsOnceThenBecomesUnavailable() async throws {
        let fix = LiveFixture()
        await fix.start()
        let first = try await fix.engine(0)
        fix.tap.mic.pushTone(seconds: 1, from: 0)
        try await waitUntil("four chunks") { await first.offered.count == 4 }
        let settled = LiveRow(track: .mic, startTime: 0, endTime: 0.4, settledText: "Hello")
        await first.emit(liveUpdate(.mic, rows: [settled], transcribedThrough: 1, settledThrough: 0.4))
        try await waitUntil("the row") { !fix.service.rows.isEmpty }

        await first.fail()
        let second = try await fix.engine(1)
        let firstConfig = try #require(await first.config)
        let secondConfig = try #require(await second.config)
        #expect(secondConfig.generation == 2)
        #expect(secondConfig.sessionID == firstConfig.sessionID)
        fix.tap.mic.pushTone(seconds: 0.5, from: 1)
        // From the settled 0.4 s: the rest of the second chunk, two more, then the new audio.
        try await waitUntil("the unsettled and the new audio") { await second.offered.count == 5 }
        let chunks = await second.offered
        #expect(abs((chunks.first?.startTime ?? 0) - 0.4) < 1e-9)
        #expect(isContiguous(chunks))
        #expect(fix.service.gaps.isEmpty, "nothing was lost")

        await second.fail()
        try await waitUntil("unavailable") { fix.service.status == .unavailable(.stopped) }
        #expect(fix.engines.engines.count == 2)
        #expect(fix.service.rows.map(\.settledText) == ["Hello"], "the drawer keeps what it has")
    }

    @Test("Stop publishes the draft at once and clears the live state")
    func stopPublishesDraftImmediately() async throws {
        let fix = LiveFixture()
        _ = try await fix.startWithRow(hello)
        let finishing = fix.service.stop(fix.meetingID)

        let draft = try #require(fix.service.draft(for: fix.meetingID))
        #expect(draft.rows == [hello])
        #expect(draft.includesTail)
        #expect(fix.service.status == .off)
        #expect(fix.service.rows.isEmpty)
        #expect(fix.service.snapshot(includeTail: true) == nil)
        fix.tap.end(at: 1)
        #expect(await finishing.value == .finished)
    }

    @Test("The engine's last words join the draft, which stays until it is released")
    func stopKeepsDraftUntilReleased() async throws {
        var final = hello
        final.settledText = "Hello world."
        final.tailText = ""
        final.isClosed = true
        let fix = LiveFixture(finish: .returns([liveUpdate(.mic, revision: 2, rows: [final], transcribedThrough: 1, settledThrough: 1)]))
        _ = try await fix.startWithRow(hello)
        let finishing = fix.service.stop(fix.meetingID)
        fix.tap.end(at: 1)

        #expect(await finishing.value == .finished)
        #expect(fix.service.draft(for: fix.meetingID)?.rows == [final])
        fix.service.releaseDraft(for: fix.meetingID)
        #expect(fix.service.draft(for: fix.meetingID) == nil)
    }

    @Test("A finishing session writes only its own meeting's draft, and only until it is released")
    func finishingSessionWritesOnlyItsOwnDraft() async throws {
        let fix = LiveFixture(finish: .hang)
        let engine = try await fix.startWithRow(hello)
        let finishing = fix.service.stop(fix.meetingID)
        fix.tap.end(at: 1)
        try await waitUntil("the finish") { await engine.isFinishing }

        fix.service.releaseDraft(for: fix.meetingID)
        var final = hello
        final.settledText = "Hello world."
        await engine.releaseFinish([liveUpdate(.mic, revision: 2, rows: [final])])
        #expect(await finishing.value == .finished)
        #expect(fix.service.draft(for: fix.meetingID) == nil)
        #expect(fix.service.rows.isEmpty, "a stopped recording never writes the live state")
    }

    @Test("A new recording cancels the earlier recording's finish; its draft keeps an incomplete tail")
    func newRecordingCancelsEarlierFinishing() async throws {
        let fix = LiveFixture(finish: .hang)
        let engine = try await fix.startWithRow(hello)
        let finishing = fix.service.stop(fix.meetingID)
        fix.tap.end(at: 1)
        try await waitUntil("the finish") { await engine.isFinishing }

        await fix.service.start(meetingID: UUID(), tap: ScriptedTap(), timelineOffset: 0)
        #expect(await finishing.value == .cancelled)
        #expect(await engine.isCancelled)
        let draft = try #require(fix.service.draft(for: fix.meetingID))
        #expect(draft.rows.first?.tailText == " wor")
        #expect(draft.rows.first?.isIncomplete == true)
    }

    @Test("Draining and finishing share the stop deadline")
    func stopDeadlineCoversDrainAndFinish() async throws {
        // The tap never ends, so draining alone runs past the deadline.
        let late = LiveFixture(stopDeadline: .milliseconds(300))
        let lateEngine = try await late.startWithRow(hello)
        let clock = ContinuousClock()
        let started = clock.now
        #expect(await late.service.stop(late.meetingID).value == .timedOut)
        #expect(clock.now - started < .seconds(2))
        #expect(await lateEngine.isCancelled)
        #expect(late.service.draft(for: late.meetingID)?.rows.first?.isIncomplete == true)

        // The engine's own finish gets what is left of the deadline, less the margin.
        let fix = LiveFixture(stopDeadline: .seconds(5))
        let engine = try await fix.startWithRow(hello)
        let stopped = clock.now
        let finishing = fix.service.stop(fix.meetingID)
        fix.tap.end(at: 1)
        #expect(await finishing.value == .finished)
        let draining = clock.now - stopped
        let timeout = try #require(await engine.finishTimeouts.first)
        // Whatever the drain took, never more than the deadline less the margin.
        #expect(timeout <= .milliseconds(4900) && timeout >= .milliseconds(4900) - draining)
    }

    @Test("A stop while the start still reads the vocabulary leaves no session behind")
    func stopDuringSetupLeavesNoSession() async throws {
        let gate = Gate()
        let fix = LiveFixture(vocabulary: { _ in
            await gate.wait()
            return []
        })
        let starting = Task { await fix.start() }
        try await waitUntil("the vocabulary read") { await gate.isWaiting }
        #expect(await fix.service.stop(fix.meetingID).value == .nothingToFinish)
        await gate.open()
        await starting.value
        #expect(fix.engines.engines.isEmpty)
        #expect(fix.service.status == .off)
    }

    @Test("Stop during a start cancels it at once instead of waiting for the model to load")
    func stopDuringStartCancelsAtOnce() async throws {
        let fix = LiveFixture(starts: [.hang])
        await fix.start()
        let engine = try await fix.engine(0)
        #expect(fix.service.status == .starting)
        #expect(await fix.service.stop(fix.meetingID).value == .nothingToFinish)
        #expect(await engine.isCancelled)
        #expect(fix.service.draft(for: fix.meetingID) == nil)
    }
}

@Suite("LiveTranscriptionService -- settings, power, language and drawer")
@MainActor
struct LiveTranscriptionServiceSettingsTests {
    @Test("Turning live transcription on mid-recording starts from now, with a start marker")
    func enablingMidRecordingSetsStartMarker() async throws {
        let fix = LiveFixture(isEnabled: false)
        await fix.start(startedAt: Date().addingTimeInterval(-5), timelineOffset: 0.5)
        #expect(fix.service.status == .off)
        #expect(fix.engines.engines.isEmpty)
        fix.tap.mic.pushTone(seconds: 6.5, from: 0)

        await fix.service.setEnabled(true)
        let marker = try #require(fix.service.startMarker)
        #expect(marker > 5.4 && marker < 6)
        let engine = try await fix.engine(0)
        try await waitUntil("a chunk") { await !engine.offered.isEmpty }
        let chunks = await engine.offered
        #expect(abs((chunks.first?.startTime ?? 0) - marker) < 1e-3)
        #expect(chunks.allSatisfy { $0.startTime >= marker - 1e-3 })
    }

    @Test("Turning live transcription off mid-recording ends it and clears the live state")
    func disablingMidRecordingClearsLiveState() async throws {
        let fix = LiveFixture()
        let engine = try await fix.startWithRow(hello)
        await fix.service.setEnabled(false)
        #expect(fix.service.status == .off)
        #expect(fix.service.rows.isEmpty)
        #expect(fix.service.snapshot(includeTail: true) == nil)
        #expect(await engine.isCancelled)
        #expect(await fix.service.stop(fix.meetingID).value == .nothingToFinish)
        #expect(fix.service.draft(for: fix.meetingID) == nil)
    }

    @Test("Low Power Mode slows the engine; heat pauses it until the Mac cools down")
    func powerPolicyPausesAndSlowsTheEngine() async throws {
        let fix = LiveFixture()
        let engine = try await fix.startWithRow(hello)
        fix.power.send(PowerState(isLowPowerModeEnabled: true))
        try await waitUntil("the slower interval") { await engine.intervals == [2] }

        fix.power.send(PowerState(isLowPowerModeEnabled: true, thermalState: .serious))
        try await waitUntil("the pause") { await engine.pausedCalls == [true] }
        #expect(fix.service.status == .paused(.lowPowerHeat))
        #expect(await engine.intervals == [2], "the interval did not change again")

        fix.power.send(PowerState(thermalState: .nominal))
        try await waitUntil("the resume") { await engine.pausedCalls.last == false }
        #expect(await engine.intervals.last == 1)
        #expect(fix.service.status == .live)
    }

    @Test("A language change finishes the running engine and starts a new generation with the new language")
    func languageChangeStartsANewGeneration() async throws {
        let fix = LiveFixture()
        await fix.start()
        let first = try await fix.engine(0)
        await fix.service.setLanguage(.detect)
        let second = try await fix.engine(1)
        #expect(await first.finishTimeouts.count == 1)
        #expect(await second.config?.language == .detect)
        #expect(await second.config?.generation == 2)
        #expect(fix.service.language == .detect)
    }

    @Test("The toggle shows while live transcription runs, and Starting records when it began")
    func visibilityAndStartingSince() async throws {
        let fix = LiveFixture()
        #expect(!fix.service.isVisible)
        #expect(fix.service.startingSince == nil)
        let before = Date()
        await fix.start()
        #expect(fix.service.isVisible)
        let since = try #require(fix.service.startingSince)
        #expect(since >= before)

        let engine = try await fix.engine(0)
        await engine.emit(liveUpdate(.mic, rows: [hello], transcribedThrough: 1))
        try await waitUntil("live") { fix.service.status == .live }
        #expect(fix.service.startingSince == nil)
        #expect(fix.service.isVisible)

        await fix.service.setEnabled(false)
        #expect(!fix.service.isVisible)
    }

    @Test("A reveal request opens the drawer and stays until the drawer handles it")
    func revealSetsRequest() throws {
        let service = makeFakeLiveService()
        #expect(!service.isDrawerExpanded)
        service.reveal(atRecordingTime: 50)
        let request = try #require(service.revealRequest)
        #expect(request.time == 50)
        #expect(service.isDrawerExpanded)
        service.revealRequestHandled(RevealRequest(time: 50))
        #expect(service.revealRequest == request, "another request for the same time is not this one")
        service.revealRequestHandled(request)
        #expect(service.revealRequest == nil)
    }

    @Test("The drawer opens as it was last left")
    func drawerStatePersists() throws {
        let suite = "live-drawer-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = makeFakeLiveService(defaults: defaults)
        #expect(!first.isDrawerExpanded, "collapsed on the first recording")
        first.toggleDrawer()
        #expect(makeFakeLiveService(defaults: defaults).isDrawerExpanded)
        first.toggleDrawer()
        #expect(!makeFakeLiveService(defaults: defaults).isDrawerExpanded)
    }

    @Test("The drawer's dragged height carries over to the next meeting until it is reset")
    func drawerHeightPersists() throws {
        let suite = "live-drawer-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = makeFakeLiveService(defaults: defaults)
        #expect(first.drawerHeight == nil, "the default height on the first recording")
        first.drawerHeight = 412
        #expect(makeFakeLiveService(defaults: defaults).drawerHeight == 412)
        first.drawerHeight = nil
        #expect(makeFakeLiveService(defaults: defaults).drawerHeight == nil)
    }

    @Test("A snapshot leaves out the tail when asked")
    func snapshotExcludesTailWhenAsked() async throws {
        let fix = LiveFixture()
        _ = try await fix.startWithRow(hello, settledThrough: 0.6)
        let full = try #require(fix.service.snapshot(includeTail: true))
        let settled = try #require(fix.service.snapshot(includeTail: false))
        #expect(full.rows == [hello])
        #expect(settled.rows.map(\.tailText) == [""])
        #expect(settled.rows.first?.endTime == 0.6)
        #expect(full.sessionID == settled.sessionID)
        #expect(full.revision == 1)
    }

    @Test("Downloading the model during a recording starts live transcription from then")
    func downloadThenStartsMidRecording() async throws {
        let fix = LiveFixture(modelPresent: false)
        await fix.start()
        #expect(fix.service.status == .unavailable(.modelMissing))
        await fix.service.downloadModel()
        #expect(fix.service.modelState == .ready)
        #expect(fix.service.startMarker != nil)
        _ = try await fix.engine(0)
        #expect(fix.service.status == .starting)
    }
}

/// True when each chunk starts where the one before it ended.
private func isContiguous(_ chunks: [LiveAudioChunk]) -> Bool {
    zip(chunks, chunks.dropFirst()).allSatisfy { abs($1.startTime - $0.endTime) < 1e-6 }
}

@Suite("LiveTranscriptionService -- audio that waits for the engine")
@MainActor
struct LiveTranscriptionServiceBacklogTests {
    @Test("Audio that arrives while the engine starts reaches it in order, with no gap")
    func slowStartKeepsTheBacklogInOrder() async throws {
        let fix = LiveFixture(starts: [.hang])
        await fix.start()
        let engine = try await fix.engine(0)
        fix.tap.mic.pushTone(seconds: 10, from: 0)
        try await waitUntil("the pump to drain the tap") { (fix.service.snapshot(includeTail: true)?.captureWatermark ?? 0) >= 10 - 1e-9 }
        #expect(await engine.offered.isEmpty)

        await engine.releaseStart()
        try await waitUntil("all forty chunks") { await engine.offered.count == 40 }
        let chunks = await engine.offered
        #expect(chunks.first?.startTime == 0)
        #expect(isContiguous(chunks))
        #expect(!chunks.contains { $0.isDiscontinuity })
        #expect(fix.service.gaps.isEmpty)
    }

    @Test("Audio a running engine refuses waits and reaches it in order once it takes chunks again")
    func refusingEngineKeepsTheBacklogInOrder() async throws {
        let fix = LiveFixture()
        await fix.start()
        let engine = try await fix.engine(0)
        await engine.setAcceptsChunks(false)
        fix.tap.mic.pushTone(seconds: 10, from: 0)
        try await waitUntil("the pump to drain the tap") { (fix.service.snapshot(includeTail: true)?.captureWatermark ?? 0) >= 10 - 1e-9 }

        await engine.setAcceptsChunks(true)
        try await waitUntil("all forty chunks") { await engine.offered.count == 40 }
        #expect(await isContiguous(engine.offered))
        #expect(fix.service.gaps.isEmpty)
    }

    @Test("Audio that arrives during a restart goes to the new engine, in order")
    func restartKeepsTheAudioThatArrivesMeanwhile() async throws {
        let fix = LiveFixture(starts: [.succeed, .hang])
        await fix.start()
        let first = try await fix.engine(0)
        fix.tap.mic.pushTone(seconds: 1, from: 0)
        try await waitUntil("four chunks") { await first.offered.count == 4 }

        await first.fail()
        let second = try await fix.engine(1)
        fix.tap.mic.pushTone(seconds: 3, from: 1)
        try await waitUntil("the pump to drain the tap") { (fix.service.snapshot(includeTail: true)?.captureWatermark ?? 0) >= 4 - 1e-9 }
        await second.releaseStart()
        try await waitUntil("sixteen chunks") { await second.offered.count == 16 }

        let chunks = await second.offered
        #expect(chunks.first?.startTime == 0, "what the failed engine held comes first")
        #expect(chunks.count == 16)
        #expect(isContiguous(chunks))
        #expect(fix.service.gaps.isEmpty)
    }

    @Test("A start mid-recording sends the audio from the marker on, in order, while the engine starts")
    func midRecordingStartKeepsTheBacklogInOrder() async throws {
        let fix = LiveFixture(starts: [.hang], isEnabled: false)
        await fix.start(startedAt: Date().addingTimeInterval(-5))
        fix.tap.mic.pushTone(seconds: 9, from: 0)
        await fix.service.setEnabled(true)
        let marker = try #require(fix.service.startMarker)
        let engine = try await fix.engine(0)
        try await waitUntil("the pump to drain the tap") { (fix.service.snapshot(includeTail: true)?.captureWatermark ?? 0) >= 9 - 1e-9 }

        await engine.releaseStart()
        let expected = Int(((9 - marker) / 0.25).rounded(.down))
        try await waitUntil("the chunks after the marker") { await engine.offered.count == expected }
        let chunks = await engine.offered
        #expect(abs((chunks.first?.startTime ?? 0) - marker) < 1e-3)
        #expect(isContiguous(chunks))
        #expect(fix.service.gaps.isEmpty)
    }

    @Test("A backlog the engine never takes cannot hold Stop past the deadline")
    func refusedBacklogEndsAtTheStopDeadline() async throws {
        let fix = LiveFixture(stopDeadline: .milliseconds(300))
        let engine = try await fix.startWithRow(hello)
        await engine.setAcceptsChunks(false)
        fix.tap.mic.pushTone(seconds: 3, from: 0)
        try await waitUntil("the pump to drain the tap") { (fix.service.snapshot(includeTail: true)?.captureWatermark ?? 0) >= 3 - 1e-9 }
        let clock = ContinuousClock()
        let started = clock.now
        let finishing = fix.service.stop(fix.meetingID)
        fix.tap.end(at: 3)
        #expect(await finishing.value == .timedOut)
        #expect(clock.now - started < .seconds(2))
        #expect(await engine.isCancelled)
        #expect(await engine.finishTimeouts.isEmpty, "the engine's finish never started: the backlog was still waiting")
        #expect(fix.service.draft(for: fix.meetingID)?.rows.first?.isIncomplete == true)
    }
}

@Suite("LiveTranscriptionService -- backfill")
@MainActor
struct LiveTranscriptionServiceBackfillTests {
    /// Starts an engine that waits, pushes audio and lets the pump take it all.
    private func startLate(mic: TimeInterval, system: TimeInterval = 0) async throws -> (LiveFixture, FakeLiveEngine) {
        let fix = LiveFixture(starts: [.hang])
        await fix.start()
        let engine = try await fix.engine(0)
        fix.tap.mic.pushTone(seconds: mic, from: 0)
        if system > 0 { fix.tap.system.pushTone(seconds: system, from: 0) }
        try await waitUntil("the pump to drain the tap") { (fix.service.snapshot(includeTail: true)?.captureWatermark ?? 0) >= mic - 1e-9 }
        await engine.releaseStart()
        return (fix, engine)
    }

    private func micChunks(of engine: FakeLiveEngine) async -> [LiveAudioChunk] {
        await engine.offered.filter { $0.track == .mic }
    }

    @Test("The engine gets a track's audio only up to the lead past what it has transcribed, then more as it goes on")
    func forwarderPacesAudioToTheEngine() async throws {
        let (fix, engine) = try await startLate(mic: 50)
        let lead = Int(LiveAudioLimits.engineLead / 0.25)
        try await waitUntil("the lead") { await micChunks(of: engine).count == lead }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await micChunks(of: engine).count == lead, "the rest waits for progress")

        await engine.emit(liveUpdate(.mic, transcribedThrough: 10, settledThrough: 10))
        try await waitUntil("ten seconds more") { await micChunks(of: engine).count == lead + 40 }
        await engine.emit(liveUpdate(.mic, revision: 2, transcribedThrough: 14, settledThrough: 14))
        try await waitUntil("all the audio") { await micChunks(of: engine).count == 200 }
        #expect(await isContiguous(micChunks(of: engine)))
        #expect(fix.service.gaps.isEmpty)
    }

    @Test("Only live chunks are measured, from the engine taking them to the update that covers them and to the drawer drawing it")
    func drawnRowsReachTheSessionsLatency() async throws {
        let (fix, engine) = try await startLate(mic: 10)
        try await waitUntil("all the audio") { await micChunks(of: engine).count == 40 }
        let live = await micChunks(of: engine).count(where: { !$0.isBackfill })
        #expect(live > 0 && live < 40, "the backlog's older half is backfill")
        let latency = try #require(fix.service.currentLatency)
        let revision = fix.service.rowsRevision

        await engine.emit(liveUpdate(.mic, rows: [hello], transcribedThrough: 10, settledThrough: 10))
        try await waitUntil("the row") { !fix.service.rows.isEmpty }
        #expect(fix.service.rowsRevision > revision)
        #expect(latency.session.chunkToUpdate.count == live)
        #expect(latency.session.chunkToDrawn.isEmpty)

        fix.service.rowsDrawn()
        #expect(latency.session.chunkToDrawn.count == live)
        #expect(latency.session.updateToDrawn.count == 1)
    }

    @Test("Audio handed over more than the backfill lag behind the newest audio is backfill; the rest is live")
    func backlogIsMarkedBackfill() async throws {
        let (fix, engine) = try await startLate(mic: 50)
        await engine.emit(liveUpdate(.mic, transcribedThrough: 20, settledThrough: 20))
        try await waitUntil("all the audio") { await micChunks(of: engine).count == 200 }

        // Captured times add up 100 ms blocks, so the chunk at the boundary itself may go either way.
        let chunks = await micChunks(of: engine)
        let lagLimit = 50 - LiveAudioLimits.backfillLag
        let behindAreBackfill = chunks.filter { $0.endTime < lagLimit - 0.1 }.allSatisfy(\.isBackfill)
        #expect(behindAreBackfill)
        #expect(chunks.filter { $0.endTime > lagLimit + 0.1 }.allSatisfy { !$0.isBackfill })
        #expect(chunks.filter(\.isBackfill).count >= Int(lagLimit / 0.25) - 1)
        #expect(fix.service.gaps.isEmpty)
    }

    @Test("A pause longer than the lead hands the paused audio over, and the transcript goes on after the resume")
    func longPauseDoesNotStopTheLiveTranscript() async throws {
        let fix = LiveFixture()
        await fix.start()
        let engine = try await fix.engine(0)
        let lead = Int(LiveAudioLimits.engineLead / 0.25)
        fix.tap.mic.pushTone(seconds: 50, from: 0)
        try await waitUntil("the lead") { await micChunks(of: engine).count == lead }

        // The session drops paused audio as one gap, so none of it waits.
        fix.power.send(PowerState(thermalState: .serious))
        try await waitUntil("the pause") { await engine.pausedCalls == [true] }
        fix.tap.mic.pushTone(seconds: 10, from: 50)
        try await waitUntil("the paused audio") { await micChunks(of: engine).count == 240 }

        fix.power.send(PowerState(thermalState: .nominal))
        try await waitUntil("the resume") { await engine.pausedCalls.last == false }
        fix.tap.mic.pushTone(seconds: 5, from: 60)
        try await waitUntil("the audio after the resume") { await micChunks(of: engine).count == 260 }
        #expect(await isContiguous(micChunks(of: engine)))
    }

    @Test("An engine restarted while it caught up gets its track's audio from the settled time, no more than the lead ahead of where it starts")
    func restartDuringCatchUpPacesTheReplay() async throws {
        let fix = LiveFixture()
        await fix.start()
        let first = try await fix.engine(0)
        fix.tap.mic.pushTone(seconds: 40, from: 0)
        try await waitUntil("the lead") { await micChunks(of: first).count == Int(LiveAudioLimits.engineLead / 0.25) }
        // Transcribed far ahead of what has settled, as when catch-up holds words back.
        await first.emit(liveUpdate(.mic, transcribedThrough: 30, settledThrough: 2))
        try await waitUntil("all the audio") { await micChunks(of: first).count == 160 }

        await first.fail()
        let second = try await fix.engine(1)
        // The failed engine's 30 s does not count for the new one.
        let replayLead = Int(LiveAudioLimits.engineLead / 0.25)
        try await waitUntil("the new engine's lead") { await micChunks(of: second).count == replayLead }
        try await Task.sleep(for: .milliseconds(100))
        let chunks = await micChunks(of: second)
        #expect(chunks.count == replayLead)
        #expect(chunks.first?.startTime == 2)
        #expect(isContiguous(chunks))

        await second.emit(liveUpdate(.mic, transcribedThrough: 10, settledThrough: 10))
        try await waitUntil("the rest") { await micChunks(of: second).count == 152 }
        #expect(fix.service.gaps.isEmpty)
    }

    @Test("A Stop that runs out of time while audio still waits marks what no engine took as not transcribed live")
    func timedOutFinishMarksTheWaitingAudio() async throws {
        let fix = LiveFixture(stopDeadline: .milliseconds(300))
        // A row keeps the draft; the engine has transcribed its first second.
        let engine = try await fix.startWithRow(hello)
        fix.tap.mic.pushTone(seconds: 60, from: 0)
        try await waitUntil("the lead") { await micChunks(of: engine).count == Int((1 + LiveAudioLimits.engineLead) / 0.25) }

        let finishing = fix.service.stop(fix.meetingID)
        fix.tap.end(at: 60)
        #expect(await finishing.value == .timedOut)

        let gaps = try #require(fix.service.draft(for: fix.meetingID)?.gaps)
        #expect(gaps.contains { $0.startTime <= 1 + LiveAudioLimits.engineLead + 0.01 && $0.endTime >= 60 - 0.01 })
    }

    @Test("Waiting audio that a timed-out Stop leaves behind is a silent gap when it was silence")
    func timedOutFinishMarksSilentWaitingAudioSilent() async throws {
        let fix = LiveFixture(stopDeadline: .milliseconds(300))
        let engine = try await fix.startWithRow(hello)
        let lead = 1 + LiveAudioLimits.engineLead
        fix.tap.mic.pushTone(seconds: lead, from: 0)
        fix.tap.mic.pushTone(seconds: 60 - lead, from: lead, amplitude: 0)
        try await waitUntil("the lead") { await micChunks(of: engine).count == Int(lead / 0.25) }

        let finishing = fix.service.stop(fix.meetingID)
        fix.tap.end(at: 60)
        #expect(await finishing.value == .timedOut)

        let gaps = try #require(fix.service.draft(for: fix.meetingID)?.gaps)
        #expect(gaps.contains { $0.isSilent && abs($0.startTime - lead) < 0.01 && abs($0.endTime - 60) < 0.01 })
        #expect(gaps.contains { !$0.isSilent && abs($0.endTime - lead) < 0.01 }, "what the engine took held sound")
    }

    @Test("One track waiting for the engine does not hold up the other")
    func waitingTrackDoesNotHoldTheOther() async throws {
        let (fix, engine) = try await startLate(mic: 50, system: 10)
        let lead = Int(LiveAudioLimits.engineLead / 0.25)
        try await waitUntil("the mic's lead and all the system track's audio") {
            let system = await engine.offered.count(where: { $0.track == .system })
            return await micChunks(of: engine).count == lead && system == 40
        }
        #expect(fix.service.gaps.isEmpty)
    }
}

@Suite("LiveTranscriptionService -- model and finish")
@MainActor
struct LiveTranscriptionServiceModelTests {
    @Test("A tail that no finish settled, as when the worker is lost, is marked incomplete")
    func lostFinishMarksTailIncomplete() async throws {
        // The fake's finish returns nothing, as a crashed worker's does.
        let fix = LiveFixture()
        _ = try await fix.startWithRow(hello)
        let finishing = fix.service.stop(fix.meetingID)
        fix.tap.end(at: 1)
        #expect(await finishing.value == .finished)
        let row = try #require(fix.service.draft(for: fix.meetingID)?.rows.first)
        #expect(row.tailText == " wor" && row.isIncomplete)
    }

    @Test("A Stop while no engine runs marks the draft's tails incomplete")
    func stopWithoutARunningEngineMarksTailsIncomplete() async throws {
        // During a language switch: the old engine's finish never returns.
        let switching = LiveFixture(finish: .hang)
        let engine = try await switching.startWithRow(hello)
        let change = Task { await switching.service.setLanguage(.detect) }
        try await waitUntil("the old engine's finish") { await engine.isFinishing }
        #expect(await switching.service.stop(switching.meetingID).value == .languageSwitchUnfinished)
        await change.value
        let switched = try #require(switching.service.draft(for: switching.meetingID)?.rows.first)
        #expect(switched.tailText == " wor" && switched.isIncomplete)

        // After live transcription stopped for the recording.
        let stopped = LiveFixture()
        await stopped.start()
        try await (stopped.engine(0)).fail()
        let second = try await stopped.engine(1)
        await second.emit(liveUpdate(.mic, rows: [hello], transcribedThrough: 1))
        try await waitUntil("the row") { !stopped.service.rows.isEmpty }
        await second.fail()
        try await waitUntil("unavailable") { stopped.service.status == .unavailable(.stopped) }
        #expect(await stopped.service.stop(stopped.meetingID).value == .nothingToFinish)
        let kept = try #require(stopped.service.draft(for: stopped.meetingID)?.rows.first)
        #expect(kept.tailText == " wor" && kept.isIncomplete)
    }

    @Test("A language switch whose finish leaves audio unsettled hands it to the new engine")
    func languageSwitchTimeoutReplaysTheUnsettledAudio() async throws {
        let settled = LiveRow(track: .mic, startTime: 0, endTime: 0.4, settledText: "Hello")
        // A finish that timed out: the tail is cut, and nothing past 0.4 s settled.
        let cut = liveUpdate(.mic, revision: 2, rows: [settled], transcribedThrough: 0.6, settledThrough: 0.4)
        let fix = LiveFixture(finish: .returns([cut]))
        await fix.start()
        let first = try await fix.engine(0)
        fix.tap.mic.pushTone(seconds: 1, from: 0)
        try await waitUntil("four chunks") { await first.offered.count == 4 }
        await first.emit(liveUpdate(.mic, rows: [settled], transcribedThrough: 1, settledThrough: 0.4))
        try await waitUntil("the row") { !fix.service.rows.isEmpty }

        await fix.service.setLanguage(.detect)
        let next = try await fix.engine(1)
        try await waitUntil("the unsettled audio") { await next.offered.count == 3 }
        #expect(await abs((next.offered.first?.startTime ?? 0) - 0.4) < 1e-9)
        #expect(fix.service.gaps.isEmpty)

        // A finish that settled everything it took leaves nothing to hand over.
        let complete = liveUpdate(.mic, revision: 2, rows: [settled], transcribedThrough: 1, settledThrough: 1)
        let clean = LiveFixture(finish: .returns([complete]))
        await clean.start()
        let engine = try await clean.engine(0)
        clean.tap.mic.pushTone(seconds: 1, from: 0)
        try await waitUntil("four chunks") { await engine.offered.count == 4 }
        await clean.service.setLanguage(.detect)
        let cleanNext = try await clean.engine(1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await cleanNext.offered.isEmpty)
        #expect(clean.service.gaps.isEmpty)
    }

    @Test("A language switch whose worker never answers, even past its stuck-decode limit, is cut off: the worker is reset and the new engine starts")
    func stuckLanguageSwitchResetsTheWorkerAndGoesOn() async throws {
        let fix = LiveFixture(finish: .hang, languageSwitchTimeout: .milliseconds(50), workerStuckDecode: .milliseconds(50))
        let resets = ResetCounter()
        fix.service.onWorkerNeedsReset = { resets.calls += 1 }
        let first = try await fix.startWithRow(hello)

        await fix.service.setLanguage(.detect)

        #expect(await first.isCancelled, "the stuck engine's connection is closed")
        #expect(resets.calls == 1, "the other connection is closed too, so the stuck worker exits")
        let next = try await fix.engine(1)
        #expect(await next.config?.generation == 2)
        #expect(await next.config?.language == .detect)
    }

    @Test("A finish slower than the switch timeout but within the worker's stuck-decode limit keeps the worker and its kept model")
    func slowLanguageSwitchKeepsTheWorker() async throws {
        let fix = LiveFixture(finish: .hang, languageSwitchTimeout: .milliseconds(50), workerStuckDecode: .seconds(30))
        let resets = ResetCounter()
        fix.service.onWorkerNeedsReset = { resets.calls += 1 }
        let first = try await fix.startWithRow(hello)
        let switching = Task { await fix.service.setLanguage(.detect) }
        try await waitUntil("the old engine's finish") { await first.isFinishing }
        // Well past the switch timeout and its margin: a slow last decode.
        try await Task.sleep(for: .milliseconds(300))

        await first.releaseFinish()
        await switching.value

        #expect(resets.calls == 0)
        #expect(await !first.isCancelled)
        let next = try await fix.engine(1)
        #expect(await next.config?.language == .detect)
    }

    @Test("Stop while the switch resets the worker still asks for a fresh worker before the final pass")
    func stopDuringTheSwitchsResetReportsItUnfinished() async throws {
        let fix = LiveFixture(finish: .hang, languageSwitchTimeout: .milliseconds(50), workerStuckDecode: .milliseconds(50))
        let gate = Gate()
        fix.service.onWorkerNeedsReset = { await gate.wait() }
        _ = try await fix.startWithRow(hello)
        let switching = Task { await fix.service.setLanguage(.detect) }
        try await waitUntil("the reset") { await gate.isWaiting }

        let result = await fix.service.stop(fix.meetingID).value
        await gate.open()
        await switching.value

        #expect(result == .languageSwitchUnfinished)
        #expect(fix.engines.engines.count == 1)
    }

    @Test("Stop while a language switch waits for the old engine asks for a fresh worker before the final pass")
    func stopDuringASwitchReportsItUnfinished() async throws {
        let fix = LiveFixture(finish: .hang, languageSwitchTimeout: .seconds(30))
        let first = try await fix.startWithRow(hello)
        let switching = Task { await fix.service.setLanguage(.detect) }
        try await waitUntil("the old engine's finish") { await first.isFinishing }

        let result = await fix.service.stop(fix.meetingID).value
        await switching.value

        #expect(result == .languageSwitchUnfinished)
        #expect(result.mayLeaveWorkerStuck)
        #expect(fix.engines.engines.count == 1, "no new engine starts after Stop")
        #expect(fix.service.draft(for: fix.meetingID)?.rows.first?.isIncomplete == true)
    }

    @Test("An engine lost during the finish ends it at once, with the lost audio as a gap")
    func engineLostWhileFinishingEndsTheFinishEarly() async throws {
        let fix = LiveFixture(stopDeadline: .seconds(5))
        let engine = try await fix.startWithRow(hello)
        await engine.setAcceptsChunks(false)
        fix.tap.mic.pushTone(seconds: 2, from: 0)
        try await waitUntil("the pump to drain the tap") { (fix.service.snapshot(includeTail: true)?.captureWatermark ?? 0) >= 2 - 1e-9 }

        let clock = ContinuousClock()
        let started = clock.now
        let finishing = fix.service.stop(fix.meetingID)
        // Let the finish begin before the engine's updates end.
        try await Task.sleep(for: .milliseconds(20))
        await engine.fail()
        fix.tap.end(at: 2)
        #expect(await finishing.value == .engineLost)
        #expect(clock.now - started < .seconds(2))
        #expect(await engine.finishTimeouts.isEmpty, "a lost engine is not asked to finish")
        let draft = try #require(fix.service.draft(for: fix.meetingID))
        #expect(draft.rows.first?.isIncomplete == true)
        let gap = try #require(draft.gaps.first { $0.reason == .engineRestart })
        #expect(gap.startTime == 0 && abs(gap.startTime + gap.duration - 2) < 1e-9)
    }

    @Test("A finish that times out, or whose engine runs out of time, records the unsettled audio as a gap")
    func failedFinishRecordsTheUnsettledAudio() async throws {
        let settled = LiveRow(track: .mic, startTime: 0, endTime: 0.4, settledText: "Hello")
        func takeASecond(_ fix: LiveFixture) async throws {
            await fix.start()
            let engine = try await fix.engine(0)
            fix.tap.mic.pushTone(seconds: 1, from: 0)
            try await waitUntil("four chunks") { await engine.offered.count == 4 }
            await engine.emit(liveUpdate(.mic, rows: [settled], transcribedThrough: 1, settledThrough: 0.4))
            try await waitUntil("the row") { !fix.service.rows.isEmpty }
        }
        func expectLostSecond(_ fix: LiveFixture, _ what: String) throws {
            let gaps = try #require(fix.service.draft(for: fix.meetingID)?.gaps, "\(what)")
            #expect(gaps.count == 1, "\(what)")
            let gap = try #require(gaps.first)
            #expect(gap.reason == .engineRestart && gap.startTime == 0.4, "\(what)")
            #expect(abs(gap.startTime + gap.duration - 1) < 1e-9, "\(what)")
        }

        // The stop deadline passes while the engine finishes.
        let late = LiveFixture(finish: .hang, stopDeadline: .milliseconds(300))
        try await takeASecond(late)
        let lateFinish = late.service.stop(late.meetingID)
        late.tap.end(at: 1)
        #expect(await lateFinish.value == .timedOut)
        try expectLostSecond(late, "deadline")

        // The engine's own finish times out and returns what it settled.
        let cut = liveUpdate(.mic, revision: 2, rows: [settled], transcribedThrough: 0.6, settledThrough: 0.4)
        let short = LiveFixture(finish: .returns([cut]))
        try await takeASecond(short)
        let shortFinish = short.service.stop(short.meetingID)
        short.tap.end(at: 1)
        #expect(await shortFinish.value == .finished)
        try expectLostSecond(short, "engine timeout")

        // A clean finish settles everything: no gap.
        let complete = liveUpdate(.mic, revision: 2, rows: [settled], transcribedThrough: 1, settledThrough: 1)
        let clean = LiveFixture(finish: .returns([complete]))
        try await takeASecond(clean)
        let cleanFinish = clean.service.stop(clean.meetingID)
        clean.tap.end(at: 1)
        #expect(await cleanFinish.value == .finished)
        #expect(clean.service.draft(for: clean.meetingID)?.gaps.isEmpty == true)
    }

    @Test("An engine that keeps refusing chunks is offered them less and less often")
    func refusingEngineIsOfferedLessOften() async throws {
        let fix = LiveFixture()
        await fix.start()
        let engine = try await fix.engine(0)
        await engine.setAcceptsChunks(false)
        fix.tap.mic.pushTone(seconds: 1, from: 0)
        try await waitUntil("a refused offer") { await engine.offerAttempts > 0 }
        try await Task.sleep(for: .milliseconds(300))
        // At a fixed 10 ms that would be about 30 offers.
        #expect(await engine.offerAttempts <= 10)

        await engine.setAcceptsChunks(true)
        try await waitUntil("all four chunks") { await engine.offered.count == 4 }
    }

    @Test("A download restarts a session whose engine found no model")
    func downloadRestartsASessionThatFoundNoModel() async throws {
        let fix = LiveFixture(starts: [.fail(.needsDownload)])
        await fix.start()
        try await waitUntil("unavailable") { fix.service.status == .unavailable(.modelMissing) }
        #expect(fix.service.modelState == .missing)

        await fix.service.downloadModel()
        #expect(fix.service.modelState == .ready)
        _ = try await fix.engine(1)
        #expect(fix.service.status == .starting)
        #expect(fix.service.startMarker != nil)
    }

    @Test("A download asked for while one runs waits for it instead of failing or starting another")
    func downloadInProgressIsAwaited() async throws {
        let model = FakeLiveModel(present: false, holdsDownloads: true)
        let service = makeFakeLiveService(model: model)
        let first = Task { await service.downloadModel() }
        try await waitUntil("the first download") { model.isDownloadWaiting }
        let second = Task { await service.downloadModel() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.downloadCount == 1)

        model.releaseDownload()
        await first.value
        await second.value
        #expect(service.modelState == .ready)
        #expect(model.downloadCount == 1)
    }
}
