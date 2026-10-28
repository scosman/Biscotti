import Foundation
import LiveTranscription
import LiveTranscriptModel
import Synchronization
import Testing
import Transcription
@testable import TranscriberWorker

/// An `EngineHost` with fake engines; live sessions are `ScriptedSession`s
/// unless a test passes its own factory.
private struct HostFixture {
    let host: EngineHost
    let log = EventLog()
    let engine: FakeHostedEngine
    let sessions: SessionFactory
    let owner = RecordingOwner()

    init(
        finalUpdates: [LiveTrackUpdate] = [],
        holdsFinish: Bool = false,
        liveDecoder: any LiveDecoder = HoldingDecoder(),
        loadGate: Gate? = nil,
        clock: some Clock<Duration> = ContinuousClock(),
        missingModels: Set<String> = [],
        stuckDecodes: Locked<Int>? = nil,
        makeSession: (@Sendable (any LiveDecoder) -> any LiveTranscriptionSession)? = nil
    ) {
        let log = log
        let engine = FakeHostedEngine(log: log)
        let sessions = SessionFactory(log: log, finalUpdates: finalUpdates, holdsFinish: holdsFinish)
        self.engine = engine
        self.sessions = sessions
        host = EngineHost(
            engine: engine,
            liveModels: FakeLiveModels(log: log, decoder: liveDecoder, loadGate: loadGate),
            modelIsPresent: { !missingModels.contains($0) },
            makeSession: makeSession ?? { sessions.make($0) },
            clock: clock,
            onStuckDecode: { stuckDecodes?.update { $0 += 1 } }
        )
    }

    /// Starts a final pass that runs until the engine releases it.
    func startFinalPass() -> Task<TranscriptResult, any Error> {
        Task { try await host.processAudio(micPath: "/tmp/mic.aac", systemPath: "/tmp/system.aac", customVocabulary: []) }
    }
}

@Suite("EngineHost")
struct EngineHostTests {
    @Test("a final pass is refused while a live session runs")
    func rejectsFinalPassWhileLive() async throws {
        let fix = HostFixture()
        try await fix.host.startLiveSession(liveConfig(), owner: fix.owner)

        await #expect(throws: TranscriptionError.workerBusy) {
            _ = try await fix.host.processAudio(micPath: "/tmp/mic.aac", systemPath: "/tmp/system.aac", customVocabulary: [])
        }
        #expect(!fix.log.all.contains("pass"))
    }

    @Test("a live session is refused while a final pass runs")
    func rejectsLiveWhileFinalPass() async throws {
        let fix = HostFixture()
        let pass = fix.startFinalPass()
        try await until { await fix.engine.isRunningPass }

        await #expect(throws: TranscriptionError.workerBusy) {
            try await fix.host.startLiveSession(liveConfig(), owner: fix.owner)
        }
        #expect(fix.sessions.last == nil)

        await fix.engine.releasePass()
        _ = try await pass.value
        #expect(await fix.host.isIdle)
    }

    @Test("cancel stops the final pass and replies once the host is idle")
    func cancelStopsTheFinalPassAndRepliesWhenIdle() async throws {
        let fix = HostFixture()
        let pass = fix.startFinalPass()
        try await until { await fix.engine.isRunningPass }

        await fix.host.cancelActiveWork()

        #expect(await fix.host.isIdle)
        #expect(await !fix.engine.isRunningPass)
        await #expect(throws: TranscriptionError.cancelled) {
            _ = try await pass.value
        }
    }

    @Test("cancel ends the live session only after its decode returns")
    func cancelEndsTheLiveSessionAfterItsDecodeReturns() async throws {
        let decoder = HoldingDecoder()
        await decoder.hold()
        let fix = HostFixture(liveDecoder: decoder) { WhisperLiveSession(decoder: $0) }
        var config = liveConfig()
        config.updateInterval = 0.1
        try await fix.host.startLiveSession(config, owner: fix.owner)
        for chunk in speech(from: 0, seconds: 1) {
            await fix.host.appendLiveAudio(sessionID: config.sessionID, generation: config.generation, chunk: chunk)
        }
        try await until { await decoder.started == 1 }

        let cancelled = Locked(false)
        let cancel = Task {
            await fix.host.cancelActiveWork()
            cancelled.update { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!cancelled.value)
        #expect(!fix.log.all.contains("unload live live-model"))

        await decoder.release()
        await cancel.value
        #expect(await decoder.returned == 1)
        #expect(fix.log.all.last == "unload live live-model")
        #expect(await fix.host.isIdle)
        // The owner did not end the session, so it hears that it ended.
        #expect(fix.owner.endedSessions == ["\(config.sessionID.uuidString) 1"])
    }

    @Test("pending updates are merged, not dropped")
    func pendingUpdatesAreMergedNotDropped() async throws {
        // The clock never moves, so only the first update goes out at once.
        let fix = HostFixture(clock: ManualClock())
        let config = liveConfig()
        try await fix.host.startLiveSession(config, owner: fix.owner)
        let session = try #require(fix.sessions.last)
        let sent = (1 ... 5).map { liveUpdate(config, revision: $0, start: Double($0)) }
        for update in sent {
            await session.send(update)
        }
        try await until { fix.owner.updates.count == 1 }

        _ = await fix.host.finishLiveSession(sessionID: config.sessionID, timeout: .seconds(10))

        let delivered = fix.owner.updates
        #expect(delivered.map(\.revision) == [1, 5])
        #expect(delivered.flatMap(\.rows).map(\.id) == sent.flatMap(\.rows).map(\.id))
        #expect(delivered.flatMap(\.gaps).count == 5)
    }

    @Test("a live session on the final pass's model shares the loaded model")
    func sharesLoadedWhisperWhenModelsMatch() async throws {
        let fix = HostFixture()
        let config = liveConfig(model: fix.engine.whisperModel)
        try await fix.host.startLiveSession(config, owner: fix.owner)
        _ = await fix.host.finishLiveSession(sessionID: config.sessionID, timeout: .seconds(1))

        #expect(fix.log.all == ["share final model", "start session 1", "finish session"])
    }

    @Test("a separate live model is unloaded before the next final pass")
    func unloadsSeparateLiveModelBeforeFinalPass() async throws {
        let fix = HostFixture()
        let config = liveConfig(model: "live-model")
        try await fix.host.startLiveSession(config, owner: fix.owner)
        _ = await fix.host.finishLiveSession(sessionID: config.sessionID, timeout: .seconds(1))
        let pass = fix.startFinalPass()
        try await until { await fix.engine.isRunningPass }
        await fix.engine.releasePass()
        _ = try await pass.value

        #expect(fix.log.all == [
            "unload final models",
            "load live live-model",
            "start session 1",
            "finish session",
            "unload live live-model",
            "pass"
        ])
    }

    @Test("finish replies once the host is idle")
    func finishRepliesWhenTheHostIsIdle() async throws {
        let config = liveConfig()
        let final = liveUpdate(config, revision: 9, start: 0)
        let fix = HostFixture(finalUpdates: [final])
        try await fix.host.startLiveSession(config, owner: fix.owner)

        let returned = await fix.host.finishLiveSession(sessionID: config.sessionID, timeout: .seconds(1))

        #expect(returned == [final])
        #expect(await fix.host.isIdle)
        #expect(fix.log.all.last == "unload live live-model")
        #expect(fix.owner.endedSessions.isEmpty)
    }

    @Test("a session that ends on its own tells its owner")
    func failedSessionTellsItsOwner() async throws {
        let fix = HostFixture()
        let config = liveConfig(generation: 3)
        try await fix.host.startLiveSession(config, owner: fix.owner)
        let session = try #require(fix.sessions.last)

        await session.fail()

        try await until { await fix.host.isIdle }
        #expect(fix.owner.endedSessions == ["\(config.sessionID.uuidString) 3"])
        #expect(fix.log.all.last == "unload live live-model")
    }

    @Test("a closed connection ends its live session")
    func closedConnectionEndsItsLiveSession() async throws {
        let fix = HostFixture()
        try await fix.host.startLiveSession(liveConfig(), owner: fix.owner)

        await fix.host.ownerDidDisconnect(RecordingOwner())
        #expect(await !fix.host.isIdle)

        await fix.host.ownerDidDisconnect(fix.owner)
        #expect(await fix.host.isIdle)
        #expect(fix.log.all.contains("cancel session"))
        #expect(fix.owner.endedSessions.isEmpty)
    }

    @Test("chunks for another session or generation are ignored")
    func chunksForAnotherGenerationAreIgnored() async throws {
        let fix = HostFixture()
        let config = liveConfig(generation: 2)
        try await fix.host.startLiveSession(config, owner: fix.owner)
        let session = try #require(fix.sessions.last)
        let chunk = speech(from: 0, seconds: 0.25)[0]

        await fix.host.appendLiveAudio(sessionID: config.sessionID, generation: 1, chunk: chunk)
        await fix.host.appendLiveAudio(sessionID: UUID(), generation: 2, chunk: chunk)
        await fix.host.appendLiveAudio(sessionID: config.sessionID, generation: 2, chunk: chunk)

        #expect(await session.appended.count == 1)
    }

    @Test("a final pass sent while a live session ends waits for the end")
    func finalPassWaitsForAnEndingSession() async throws {
        let decoder = HoldingDecoder()
        await decoder.hold()
        let fix = HostFixture(liveDecoder: decoder) { WhisperLiveSession(decoder: $0) }
        var config = liveConfig()
        config.updateInterval = 0.1
        try await fix.host.startLiveSession(config, owner: fix.owner)
        for chunk in speech(from: 0, seconds: 1) {
            await fix.host.appendLiveAudio(sessionID: config.sessionID, generation: config.generation, chunk: chunk)
        }
        try await until { await decoder.started == 1 }
        let cancel = Task { await fix.host.cancelLiveSession(sessionID: config.sessionID) }
        try await until { if case .endingLive = await fix.host.activity { true } else { false } }

        let pass = fix.startFinalPass()
        try await Task.sleep(for: .milliseconds(30))
        #expect(!fix.log.all.contains("pass"))

        await decoder.release()
        await cancel.value
        try await until { await fix.engine.isRunningPass }
        await fix.engine.releasePass()
        _ = try await pass.value
        #expect(fix.log.all.suffix(2) == ["unload live live-model", "pass"])
    }
}

@Suite("EngineHost - a stuck decode")
struct EngineHostStuckDecodeTests {
    @Test("A decode still out 10 s after its session ended on the kept model ends the worker; the model is never unloaded under it and nothing else starts")
    func stuckDecodeEndsTheWorker() async throws {
        let decoder = HoldingDecoder()
        let clock = ManualClock()
        let exits = Locked(0)
        let fix = HostFixture(liveDecoder: decoder, clock: clock, stuckDecodes: exits) { WhisperLiveSession(decoder: $0) }
        // The kept model, as the app's other connection asks for it.
        _ = try await fix.host.startPreparation(models: ["live-model"], keepLoaded: "live-model", owner: fix.owner).prepared
        await decoder.hold()
        var config = liveConfig()
        config.updateInterval = 0.1
        try await fix.host.startLiveSession(config, owner: fix.owner)
        for chunk in speech(from: 0, seconds: 1) {
            await fix.host.appendLiveAudio(sessionID: config.sessionID, generation: config.generation, chunk: chunk)
        }
        try await until { await decoder.started == 1 }
        let cancel = Task { await fix.host.cancelLiveSession(sessionID: config.sessionID) }
        try await until { if case .endingLive = await fix.host.activity { true } else { false } }
        let pass = fix.startFinalPass()

        try await until {
            clock.advance(by: .seconds(1))
            return exits.value == 1
        }

        #expect(await fix.host.resident?.name == "live-model", "the kept model stays loaded under the stuck decode")
        #expect(!fix.log.all.contains("unload live live-model"))
        #expect(!fix.log.all.contains("pass"), "the final pass waits; in the app the worker has ended by now")
        await decoder.release()
        await cancel.value
        try await until { await fix.engine.isRunningPass }
        await fix.engine.releasePass()
        _ = try await pass.value
        #expect(exits.value == 1)
    }

    @Test("A decode that returns just inside the limit ends the session as before, with no exit then or later")
    func decodeReturningInTimeDoesNotEndTheWorker() async throws {
        let decoder = HoldingDecoder()
        let clock = ManualClock()
        let exits = Locked(0)
        let fix = HostFixture(liveDecoder: decoder, clock: clock, stuckDecodes: exits) { WhisperLiveSession(decoder: $0) }
        await decoder.hold()
        var config = liveConfig()
        config.updateInterval = 0.1
        try await fix.host.startLiveSession(config, owner: fix.owner)
        for chunk in speech(from: 0, seconds: 1) {
            await fix.host.appendLiveAudio(sessionID: config.sessionID, generation: config.generation, chunk: chunk)
        }
        try await until { await decoder.started == 1 }
        let sleepersBefore = clock.sleeperCount
        let cancel = Task { await fix.host.cancelLiveSession(sessionID: config.sessionID) }
        try await until { clock.sleeperCount > sleepersBefore }

        clock.advance(by: EngineHost.stuckDecodeLimit - .seconds(1))
        try await Task.sleep(for: .milliseconds(20))
        #expect(exits.value == 0)
        await decoder.release()
        await cancel.value
        clock.advance(by: .seconds(5))
        try await Task.sleep(for: .milliseconds(20))

        #expect(await fix.host.isIdle)
        #expect(exits.value == 0)
    }
}

@Suite("EngineHost - cancelling")
struct EngineHostCancelTests {
    private func isEnding(_ host: EngineHost) async -> Bool {
        if case .endingLive = await host.activity { true } else { false }
    }

    @Test("a cancel cuts a finishing session short")
    func cancelCutsAFinishShort() async throws {
        let fix = HostFixture(holdsFinish: true)
        let config = liveConfig()
        try await fix.host.startLiveSession(config, owner: fix.owner)
        let started = ContinuousClock.now
        let finish = Task { await fix.host.finishLiveSession(sessionID: config.sessionID, timeout: .seconds(30)) }
        try await until { await isEnding(fix.host) }

        await fix.host.cancelActiveWork()

        #expect(await finish.value.isEmpty)
        #expect(await fix.host.isIdle)
        #expect(started.duration(to: .now) < .seconds(5))
        #expect(fix.log.all.suffix(3) == ["finish session", "cancel session", "unload live live-model"])
    }

    @Test("cancelling a finishing session ends it at once")
    func cancelLiveSessionCutsAFinishShort() async throws {
        let fix = HostFixture(holdsFinish: true)
        let config = liveConfig()
        try await fix.host.startLiveSession(config, owner: fix.owner)
        let finish = Task { await fix.host.finishLiveSession(sessionID: config.sessionID, timeout: .seconds(30)) }
        try await until { await isEnding(fix.host) }

        await fix.host.cancelLiveSession(sessionID: config.sessionID)

        #expect(await finish.value.isEmpty)
        #expect(await fix.host.isIdle)
        #expect(fix.owner.endedSessions.isEmpty)
    }

    @Test("a pass that waited through a cancel does not start")
    func passWaitingThroughACancelIsCancelled() async throws {
        let fix = HostFixture(holdsFinish: true)
        let config = liveConfig()
        try await fix.host.startLiveSession(config, owner: fix.owner)
        let finish = Task { await fix.host.finishLiveSession(sessionID: config.sessionID, timeout: .seconds(30)) }
        try await until { await isEnding(fix.host) }
        let pass = fix.startFinalPass()
        try await until { await fix.host.waiterCount == 1 }

        await fix.host.cancelActiveWork()

        await #expect(throws: TranscriptionError.cancelled) {
            _ = try await pass.value
        }
        _ = await finish.value
        #expect(!fix.log.all.contains("pass"))
        #expect(await fix.host.isIdle)
    }

    @Test("a live start cancelled while its model loads ends without running")
    func startCancelledWhileLoadingEnds() async throws {
        let gate = Gate()
        let fix = HostFixture(loadGate: gate)
        let config = liveConfig()
        let start = Task { try await fix.host.startLiveSession(config, owner: fix.owner) }
        try await until { await gate.waiting == 1 }

        let cancel = Task { await fix.host.cancelLiveSession(sessionID: config.sessionID) }
        try await until { await fix.host.startIsCancelled }
        await gate.open()

        await #expect(throws: TranscriptionError.cancelled) {
            try await start.value
        }
        await cancel.value
        #expect(await fix.host.isIdle)
        #expect(fix.log.all.suffix(2) == ["cancel session", "unload live live-model"])
    }
}

@Suite("EngineHost - idle wait")
struct EngineHostIdleWaitTests {
    @Test("a pass sent during a slow live start is refused, and the idle wait ends with the session")
    func idleWaitEndsWhenTheLiveSessionEnds() async throws {
        let gate = Gate()
        let fix = HostFixture(loadGate: gate)
        let config = liveConfig()
        let start = Task { try await fix.host.startLiveSession(config, owner: fix.owner) }
        try await until { await gate.waiting == 1 }

        await #expect(throws: TranscriptionError.workerBusy) {
            _ = try await fix.host.processAudio(micPath: "/tmp/mic.aac", systemPath: "/tmp/system.aac", customVocabulary: [])
        }
        let idle = Locked(false)
        let wait = Task {
            await fix.host.waitUntilIdle()
            idle.update { $0 = true }
        }
        await gate.open()
        try await start.value
        try await Task.sleep(for: .milliseconds(20))
        #expect(!idle.value)

        _ = await fix.host.finishLiveSession(sessionID: config.sessionID, timeout: .seconds(1))
        await wait.value
        #expect(idle.value)
        #expect(!fix.log.all.contains("pass"))
    }
}

@Suite("EngineHost -- model preparation")
struct EngineHostPreparationTests {
    @Test("a preparation loads and unloads each model in order, after the final pass's models")
    func preparationLoadsAndUnloadsEachPresentModel() async throws {
        let fix = HostFixture()
        let preparation = try await fix.host.startPreparation(models: ["live-model", "final-model"], owner: fix.owner)

        #expect(await preparation.prepared == ["live-model", "final-model"])
        #expect(fix.log.all == [
            "unload final models",
            "load live live-model", "unload live live-model",
            "load live final-model", "unload live final-model"
        ])
        try await until { await fix.host.isIdle }
    }

    @Test("a model kept loaded stays loaded, and live sessions on it neither load nor unload it")
    func keptModelServesLiveSessions() async throws {
        let fix = HostFixture()
        let preparation = try await fix.host.startPreparation(models: ["live-model"], keepLoaded: "live-model", owner: fix.owner)
        #expect(await preparation.prepared == ["live-model"])
        try await until { await fix.host.isIdle }

        for _ in 0 ..< 2 {
            let config = liveConfig(model: "live-model")
            try await fix.host.startLiveSession(config, owner: fix.owner)
            _ = await fix.host.finishLiveSession(sessionID: config.sessionID, timeout: .seconds(1))
        }

        #expect(fix.log.all.filter { $0.hasPrefix("load live") || $0.hasPrefix("unload live") } == ["load live live-model"])
        #expect(await fix.host.resident?.name == "live-model")
    }

    @Test("preparing a model already kept loaded loads nothing; a different live model replaces it")
    func residentModelIsReplacedByAnotherLiveModel() async throws {
        let fix = HostFixture()
        _ = try await fix.host.startPreparation(models: ["live-model"], keepLoaded: "live-model", owner: fix.owner).prepared
        try await until { await fix.host.isIdle }
        #expect(try await fix.host.startPreparation(models: ["live-model"], keepLoaded: "live-model", owner: fix.owner).prepared == ["live-model"])
        try await until { await fix.host.isIdle }

        let config = liveConfig(model: "other-model")
        try await fix.host.startLiveSession(config, owner: fix.owner)

        #expect(fix.log.all.filter { $0.hasPrefix("load live") || $0.hasPrefix("unload live") } == [
            "load live live-model", "unload live live-model", "load live other-model"
        ])
        #expect(await fix.host.resident == nil)
    }

    @Test("a final pass runs with the model kept loaded still loaded, and leaves it loaded")
    func finalPassKeepsTheKeptModel() async throws {
        let fix = HostFixture()
        _ = try await fix.host.startPreparation(models: ["live-model"], keepLoaded: "live-model", owner: fix.owner).prepared
        try await until { await fix.host.isIdle }

        let pass = fix.startFinalPass()
        try await until { fix.log.all.contains("pass") }
        await fix.engine.releasePass()
        _ = try await pass.value

        let events = fix.log.all.filter { $0.hasPrefix("load live") || $0.hasPrefix("unload live") || $0 == "pass" }
        #expect(events == ["load live live-model", "pass"])
        #expect(await fix.host.resident?.name == "live-model")
    }

    @Test("a final pass reports its model loads, and the next pass does not inherit the report")
    func finalPassReportsModelLoads() async throws {
        let fix = HostFixture()
        let seen = Locked<[Bool]>([])
        let pass = try await fix.host.startFinalPass(micPath: "/tmp/mic.aac", systemPath: "/tmp/system.aac", customVocabulary: []) { isLoading in
            seen.update { $0.append(isLoading) }
        }
        await fix.engine.releasePass()
        _ = try await pass.result
        _ = try await fix.host.processAudio(micPath: "/tmp/mic.aac", systemPath: "/tmp/system.aac", customVocabulary: [])

        #expect(seen.value == [true, false])
    }

    @Test("Record during a pass: the pass is cancelled, its models unloaded, and live starts on the kept model with no load")
    func recordDuringAPassStartsOnTheKeptModel() async throws {
        let fix = HostFixture()
        _ = try await fix.host.startPreparation(models: ["live-model"], keepLoaded: "live-model", owner: fix.owner).prepared
        try await until { await fix.host.isIdle }
        let pass = fix.startFinalPass()
        try await until { fix.log.all.contains("pass") }

        await fix.host.cancelActiveWork()
        _ = try? await pass.value
        let before = fix.log.all.count
        try await fix.host.startLiveSession(liveConfig(model: "live-model"), owner: fix.owner)

        #expect(fix.log.all.dropFirst(before).contains("unload final models"))
        #expect(fix.log.all.count(where: { $0 == "load live live-model" }) == 1, "the kept model is not loaded again")
    }

    @Test("preparing another model keeps the kept one loaded; a reload reads the kept one's files again")
    func preparationKeepsTheKeptModel() async throws {
        let fix = HostFixture()
        _ = try await fix.host.startPreparation(models: ["live-model"], keepLoaded: "live-model", owner: fix.owner).prepared
        try await until { await fix.host.isIdle }

        let both = try await fix.host.startPreparation(models: ["live-model", "final-model"], keepLoaded: "live-model", owner: fix.owner)
        #expect(await both.prepared == ["live-model", "final-model"])
        try await until { await fix.host.isIdle }
        #expect(try await fix.host.startPreparation(models: ["live-model"], keepLoaded: "live-model", reloadingKept: true, owner: fix.owner).prepared == ["live-model"])
        try await until { await fix.host.isIdle }

        let events = fix.log.all.filter { $0.hasPrefix("load live") || $0.hasPrefix("unload live") }
        #expect(events == [
            "load live live-model",
            "load live final-model", "unload live final-model",
            "unload live live-model", "load live live-model"
        ])
        #expect(await fix.host.resident?.name == "live-model")
    }

    @Test("a model that is not on disk is skipped, never downloaded")
    func preparationSkipsMissingModels() async throws {
        let fix = HostFixture(missingModels: ["final-model"])
        let preparation = try await fix.host.startPreparation(models: ["final-model", "live-model"], owner: fix.owner)

        #expect(await preparation.prepared == ["live-model"])
        #expect(!fix.log.all.contains("load live final-model"))
    }

    @Test("cancel stops a preparation after the model loading at the time and replies once idle")
    func cancelActiveWorkStopsPreparationBetweenModels() async throws {
        let gate = Gate()
        let fix = HostFixture(loadGate: gate)
        let preparation = try await fix.host.startPreparation(models: ["live-model", "final-model"], owner: fix.owner)
        try await until { await gate.waiting == 1 }

        let cancel = Task { await fix.host.cancelActiveWork() }
        try await until { await fix.host.waiterCount == 1 }
        #expect(await !fix.host.isIdle, "the load in progress cannot be interrupted")
        await gate.open()
        await cancel.value

        #expect(await fix.host.isIdle)
        #expect(await preparation.prepared == ["live-model"])
        #expect(!fix.log.all.contains("load live final-model"))
    }

    @Test("a final pass or a live start during a preparation is refused as busy")
    func workDuringPreparationIsBusy() async throws {
        let gate = Gate()
        let fix = HostFixture(loadGate: gate)
        let preparation = try await fix.host.startPreparation(models: ["live-model"], owner: fix.owner)
        try await until { await gate.waiting == 1 }

        await #expect(throws: TranscriptionError.workerBusy) {
            _ = try await fix.host.processAudio(micPath: "/tmp/mic.aac", systemPath: "/tmp/system.aac", customVocabulary: [])
        }
        await #expect(throws: TranscriptionError.workerBusy) {
            try await fix.host.startLiveSession(liveConfig(), owner: fix.owner)
        }
        await gate.open()
        _ = await preparation.prepared
        try await until { await fix.host.isIdle }
    }

    @Test("a preparation is refused while other work runs")
    func preparationRefusedWhileBusy() async throws {
        let fix = HostFixture()
        try await fix.host.startLiveSession(liveConfig(), owner: fix.owner)

        await #expect(throws: TranscriptionError.workerBusy) {
            _ = try await fix.host.startPreparation(models: ["live-model"], owner: fix.owner)
        }
    }

    @Test("a closed connection cancels its preparation")
    func disconnectCancelsPreparation() async throws {
        let gate = Gate()
        let fix = HostFixture(loadGate: gate)
        let preparation = try await fix.host.startPreparation(models: ["live-model", "final-model"], owner: fix.owner)
        try await until { await gate.waiting == 1 }

        await fix.host.ownerDidDisconnect(fix.owner)
        await gate.open()

        #expect(await preparation.prepared == ["live-model"])
        try await until { await fix.host.isIdle }
    }
}

@Suite("TranscriberService")
struct TranscriberServiceTests {
    private func passRequest() throws -> Data {
        try JSONEncoder().encode(XPCProcessRequest(micPath: "/tmp/mic.aac", systemPath: "/tmp/system.aac", customVocabulary: []))
    }

    @Test("a cancel sent right after a pass stops it")
    func cancelSentAfterAPassStopsIt() async throws {
        let fix = HostFixture()
        let service = TranscriberService(connection: nil, host: fix.host)
        let replies = Locked<[String]>([])

        try service.processAudio(requestData: passRequest()) { _, error in
            let outcome = (error as? TranscriptionError).map { "\($0)" } ?? "transcript"
            replies.update { $0.append("pass \(outcome)") }
        }
        service.cancelActiveWork { replies.update { $0.append("idle") } }

        try await until { replies.value.count == 2 }
        #expect(Set(replies.value) == ["pass cancelled", "idle"])
        #expect(await fix.host.isIdle)
    }

    @Test("a live cancel reaches a finish that is still running")
    func liveCancelReachesARunningFinish() async throws {
        let fix = HostFixture(holdsFinish: true)
        let service = TranscriberService(connection: nil, host: fix.host)
        let config = liveConfig()
        let replies = Locked<[String]>([])
        try service.startLiveSession(configData: JSONEncoder().encode(config)) { error in
            replies.update { $0.append(error == nil ? "started" : "start failed") }
        }
        try await until { replies.value == ["started"] }

        service.finishLiveSession(sessionID: config.sessionID.uuidString, timeoutSeconds: 30) { data, _ in
            replies.update { $0.append("finished with \(data.flatMap { String(bytes: $0, encoding: .utf8) } ?? "nothing")") }
        }
        try await until { if case .endingLive = await fix.host.activity { true } else { false } }
        service.cancelLiveSession(sessionID: config.sessionID.uuidString) {
            replies.update { $0.append("cancelled") }
        }

        try await until { replies.value.count == 3 }
        #expect(Set(replies.value.dropFirst()) == ["finished with []", "cancelled"])
        #expect(await fix.host.isIdle)
    }

    @Test("a cancel cuts a finish short even with a pass waiting ahead of it")
    func cancelCutsAFinishShortPastAWaitingPass() async throws {
        let fix = HostFixture(holdsFinish: true)
        let service = TranscriberService(connection: nil, host: fix.host)
        let config = liveConfig()
        let replies = Locked<[String]>([])
        try await startLive(config, on: service, replies: replies)
        service.finishLiveSession(sessionID: config.sessionID.uuidString, timeoutSeconds: 30) { _, _ in
            replies.update { $0.append("finished") }
        }
        try await until { if case .endingLive = await fix.host.activity { true } else { false } }
        // This pass waits in the admission inbox for the session to end.
        try service.processAudio(requestData: passRequest()) { _, error in
            replies.update { $0.append("pass \((error as? TranscriptionError).map { "\($0)" } ?? "transcript")") }
        }
        try await until { await fix.host.waiterCount == 1 }

        service.cancelActiveWork { replies.update { $0.append("idle") } }

        try await until { replies.value.count == 4 }
        #expect(Set(replies.value.dropFirst()) == ["finished", "pass cancelled", "idle"])
        #expect(!fix.log.all.contains("pass"))
    }

    @Test("a preparation replies with the models prepared; a cancel sent after it stops it")
    func cancelSentAfterAPreparationStopsIt() async throws {
        let gate = Gate()
        let fix = HostFixture(loadGate: gate)
        let service = TranscriberService(connection: nil, host: fix.host)
        let replies = Locked<[String]>([])

        try service.prepareModels(requestData: JSONEncoder().encode(ModelPreparationRequest(models: ["live-model", "final-model"]))) { data, error in
            let prepared = data.flatMap { try? JSONDecoder().decode([String].self, from: $0) }
            replies.update { $0.append(error == nil ? "prepared \(prepared ?? [])" : "failed") }
        }
        service.cancelActiveWork { replies.update { $0.append("idle") } }
        // The cancel lands before the first load or during it; either way no
        // later model loads.
        await gate.open()

        try await until { replies.value.count == 2 }
        #expect(replies.value.contains("idle"))
        #expect(replies.value.contains("prepared []") || replies.value.contains("prepared [\"live-model\"]"))
        #expect(!fix.log.all.contains("load live final-model"))
        #expect(await fix.host.isIdle)
    }

    @Test("a closed connection stops its running pass")
    func closedConnectionStopsItsRunningPass() async throws {
        let fix = HostFixture()
        let service = TranscriberService(connection: nil, host: fix.host)
        let replies = Locked<[String]>([])
        try service.processAudio(requestData: passRequest()) { _, error in
            replies.update { $0.append((error as? TranscriptionError).map { "\($0)" } ?? "transcript") }
        }
        try await until { await fix.engine.isRunningPass }

        service.connectionDidClose()

        try await until { replies.value.count == 1 }
        #expect(replies.value == ["cancelled"])
        try await until { await fix.host.isIdle }
    }

    @Test("a closed connection refuses the passes it queued")
    func closedConnectionRefusesItsQueuedPasses() async throws {
        let fix = HostFixture(holdsFinish: true)
        let service = TranscriberService(connection: nil, host: fix.host)
        let config = liveConfig()
        let replies = Locked<[String]>([])
        try await startLive(config, on: service, replies: replies)
        service.finishLiveSession(sessionID: config.sessionID.uuidString, timeoutSeconds: 30) { _, _ in }
        try await until { if case .endingLive = await fix.host.activity { true } else { false } }
        for _ in 0 ..< 2 {
            try service.processAudio(requestData: passRequest()) { _, error in
                replies.update { $0.append((error as? TranscriptionError).map { "\($0)" } ?? "transcript") }
            }
        }
        try await until { await fix.host.waiterCount == 1 }

        service.connectionDidClose()

        try await until { replies.value.count == 3 }
        #expect(Array(replies.value.dropFirst()) == ["cancelled", "cancelled"])
        try await until { await fix.host.isIdle }
    }

    private func startLive(_ config: LiveSessionConfig, on service: TranscriberService, replies: Locked<[String]>) async throws {
        try service.startLiveSession(configData: JSONEncoder().encode(config)) { error in
            replies.update { $0.append(error == nil ? "started" : "start failed") }
        }
        try await until { replies.value == ["started"] }
    }

    @Test("a closed connection stops its live start while the model loads")
    func closedConnectionStopsAStartInProgress() async throws {
        let gate = Gate()
        let fix = HostFixture(loadGate: gate)
        let service = TranscriberService(connection: nil, host: fix.host)
        let replies = Locked<[String]>([])
        try service.startLiveSession(configData: JSONEncoder().encode(liveConfig())) { error in
            let outcome = (error as? TranscriptionError).map { "\($0)" } ?? "started"
            replies.update { $0.append(outcome) }
        }
        try await until { await gate.waiting == 1 }

        service.connectionDidClose()
        try await until { await fix.host.startIsCancelled }
        await gate.open()

        try await until { replies.value.count == 1 }
        #expect(replies.value == ["cancelled"])
        try await until { await fix.host.isIdle }
        #expect(fix.log.all.contains("cancel session"))
    }
}

@Suite("LiveUpdateRelay")
struct LiveUpdateRelayTests {
    private final class Sent: Sendable {
        private let updates = Mutex<[LiveTrackUpdate]>([])

        var all: [LiveTrackUpdate] {
            updates.withLock { $0 }
        }

        func add(_ update: LiveTrackUpdate) {
            updates.withLock { $0.append(update) }
        }
    }

    @Test("each track sends at most one update every quarter second")
    func sendsAtMostOneUpdatePerTrackEveryQuarterSecond() async throws {
        let clock = ManualClock()
        let sent = Sent()
        let relay = LiveUpdateRelay(clock: HostClock(clock)) { sent.add($0) }
        let config = liveConfig()

        await relay.receive(liveUpdate(config, revision: 1, start: 0))
        await relay.receive(liveUpdate(config, revision: 2, start: 1))
        await relay.receive(liveUpdate(config, revision: 3, start: 2))
        await relay.receive(liveUpdate(config, track: .system, revision: 4, start: 0))
        #expect(sent.all.map(\.revision) == [1, 4])

        try await until { clock.sleeperCount == 1 }
        clock.advance(by: .milliseconds(249))
        try await Task.sleep(for: .milliseconds(20))
        #expect(sent.all.map(\.revision) == [1, 4])

        clock.advance(by: .milliseconds(1))
        try await until { sent.all.count == 3 }
        let merged = try #require(sent.all.last)
        #expect(merged.revision == 3)
        #expect(merged.rows.map(\.settledText) == ["row 2", "row 3"])
    }

    @Test("flush sends the pending updates at once")
    func flushSendsPendingUpdates() async {
        let sent = Sent()
        let relay = LiveUpdateRelay(clock: HostClock(ManualClock())) { sent.add($0) }
        let config = liveConfig()
        await relay.receive(liveUpdate(config, revision: 1, start: 0))
        await relay.receive(liveUpdate(config, revision: 2, start: 1))

        await relay.flush()
        await relay.flush()

        #expect(sent.all.map(\.revision) == [1, 2])
    }
}

@Suite("SerialInbox")
struct SerialInboxTests {
    @Test("work runs one item at a time in arrival order")
    func runsWorkInArrivalOrder() async throws {
        let inbox = SerialInbox()
        let order = Locked<[Int]>([])
        let running = Locked(0)
        let overlapped = Locked(false)
        for index in 0 ..< 20 {
            inbox.add {
                let concurrent = running.update { count in
                    count += 1
                    return count
                }
                if concurrent > 1 { overlapped.update { $0 = true } }
                if index.isMultiple(of: 3) {
                    try? await Task.sleep(for: .milliseconds(2))
                }
                order.update { $0.append(index) }
                running.update { $0 -= 1 }
            }
        }

        try await until { order.value.count == 20 }
        #expect(order.value == Array(0 ..< 20))
        #expect(!overlapped.value)
    }
}
