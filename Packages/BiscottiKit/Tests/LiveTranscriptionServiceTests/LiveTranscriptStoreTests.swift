import BiscottiTestSupport
import Foundation
import LiveTranscriptModel
import Synchronization
import Testing
@testable import LiveTranscriptionService

private func makeStore(onViolation: @escaping @Sendable (String) -> Void = { _ in }) -> LiveTranscriptStore {
    var store = LiveTranscriptStore(sessionID: UUID(), onSettledTextViolation: onViolation)
    store.beginGeneration(1)
    return store
}

private func update(
    _ store: LiveTranscriptStore,
    _ track: LiveTrack = .mic,
    revision: Int = 1,
    rows: [LiveRow] = [],
    gaps: [LiveGap] = [],
    transcribed: TimeInterval = 0,
    settled: TimeInterval = 0
) -> LiveTrackUpdate {
    LiveTrackUpdate(
        sessionID: store.sessionID, generation: store.generation, track: track, revision: revision,
        rows: rows, gaps: gaps, transcribedThrough: transcribed, settledThrough: settled
    )
}

@Suite("LiveTranscriptStore")
struct LiveTranscriptStoreTests {
    @Test("Rows from both tracks come out in start-time order")
    func mergesTracksInTimeOrder() {
        var store = makeStore()
        let you = LiveRow(track: .mic, startTime: 2, endTime: 3, settledText: "Hi")
        let others = LiveRow(track: .system, startTime: 1, endTime: 2, settledText: "Hello")
        let later = LiveRow(track: .system, startTime: 4, endTime: 5, settledText: "Bye")
        store.apply(update(store, .mic, rows: [you]))
        store.apply(update(store, .system, rows: [others, later]))
        #expect(store.rows.map(\.id) == [others.id, you.id, later.id])
    }

    @Test("An update replaces the row with the same ID, keeping it in place")
    func updateReplacesTailKeepsID() {
        var store = makeStore()
        var row = LiveRow(track: .mic, startTime: 1, endTime: 2, settledText: "Hello", tailText: " there")
        store.apply(update(store, rows: [row]))
        row.settledText = "Hello there"
        row.tailText = " friend"
        row.endTime = 3
        store.apply(update(store, revision: 2, rows: [row]))
        #expect(store.rows == [row])
    }

    @Test("Updates from another generation or session are ignored")
    func staleGenerationIsIgnored() {
        var store = makeStore()
        let row = LiveRow(track: .mic, startTime: 1, endTime: 2, settledText: "Old")
        var old = update(store, rows: [row])
        store.beginGeneration(2)
        let staleApplied = store.apply(old)
        #expect(!staleApplied)
        old.generation = 2
        old.sessionID = UUID()
        let otherSessionApplied = store.apply(old)
        #expect(!otherSessionApplied)
        #expect(store.rows.isEmpty)
        #expect(!store.hasUpdates)
    }

    @Test("An update older than one already applied for its track is ignored")
    func lowerRevisionIsIgnored() {
        var store = makeStore()
        var row = LiveRow(track: .mic, startTime: 1, endTime: 2, settledText: "One two")
        store.apply(update(store, revision: 5, rows: [row], settled: 2))
        row.settledText = "One two three"
        let older = update(store, revision: 4, rows: [row], settled: 1)
        let olderApplied = store.apply(older)
        #expect(!olderApplied)
        #expect(store.rows.first?.settledText == "One two")
        #expect(store.settledThrough(.mic) == 2)
        let system = update(store, .system, revision: 1)
        let systemApplied = store.apply(system)
        #expect(systemApplied, "each track keeps its own revision")
    }

    @Test("Settled text that changes instead of growing is rejected and reported")
    func nonAppendOnlySettledTextIsRejectedAndLogged() {
        let reports = Mutex<[String]>([])
        var store = makeStore { message in reports.withLock { $0.append(message) } }
        var row = LiveRow(track: .mic, startTime: 1, endTime: 2, settledText: "We ship Friday")
        store.apply(update(store, rows: [row]))
        row.settledText = "We shipped Friday"
        store.apply(update(store, revision: 2, rows: [row]))
        #expect(store.rows.first?.settledText == "We ship Friday")
        #expect(reports.withLock(\.count) == 1)
        #expect(reports.withLock { $0.first?.contains("Friday") } == false, "no transcript text in the report")
    }

    @Test("An active track more than 10 s behind the captured audio is catching up")
    func catchingUpAfterTenSecondsBehind() {
        var store = makeStore()
        store.recordCapture([.mic: 20, .system: 20])
        store.apply(update(store, .mic, transcribed: 15))
        store.apply(update(store, .system, transcribed: 10.5))
        #expect(!store.isCatchingUp)
        store.recordCapture([.mic: 21, .system: 21])
        #expect(store.isCatchingUp)
    }

    @Test("A track that stops delivering is not active: it holds back neither the settled time nor the status")
    func stalledTrackIsNotActive() {
        var store = makeStore()
        store.recordCapture([.mic: 30, .system: 5])
        store.apply(update(store, .mic, transcribed: 29, settled: 28))
        store.apply(update(store, .system, transcribed: 4, settled: 4))
        #expect(store.activeTracks == [.mic])
        #expect(!store.isCatchingUp)
        #expect(store.snapshot(includeTail: false).settledThrough == 28)
        store.recordCapture([.system: 29])
        #expect(store.activeTracks == [.mic, .system])
        #expect(store.isCatchingUp, "the system track is back and 25 s behind")
    }

    @Test("The session's gap for a discontinuity and the pump's gap for the same stretch count once")
    func duplicateGapsAreMerged() {
        var store = makeStore()
        store.addGap(LiveGap(track: .mic, startTime: 5, duration: 2, reason: .queueOverflow))
        store.apply(update(store, gaps: [LiveGap(track: .mic, startTime: 5, duration: 2, reason: .captureGap)]))
        store.addGap(LiveGap(track: .mic, startTime: 7, duration: 0.5, reason: .queueOverflow))
        store.addGap(LiveGap(track: .system, startTime: 5, duration: 1, reason: .captureGap))
        #expect(store.gaps == [
            LiveGap(track: .mic, startTime: 5, duration: 2.5, reason: .queueOverflow),
            LiveGap(track: .system, startTime: 5, duration: 1, reason: .captureGap)
        ])
    }

    @Test("A later report of a stretch keeps the earlier report's silence")
    func duplicateReportKeepsTheEarlierSilence() {
        var store = makeStore()
        // The pump dropped 3 s of silence; the session repeats the stretch without knowing its audio.
        store.addGap(LiveGap(track: .mic, startTime: 5, duration: 3, reason: .queueOverflow, isSilent: true))
        store.apply(update(store, gaps: [LiveGap(track: .mic, startTime: 5, duration: 3, reason: .captureGap)]))
        #expect(store.gaps == [LiveGap(track: .mic, startTime: 5, duration: 3, reason: .queueOverflow, isSilent: true)])
    }

    @Test("A report adds only the time no gap covers, joined to touching gaps of the same silence")
    func newStretchesJoinOnlyGapsOfTheSameSilence() {
        var store = makeStore()
        store.apply(update(store, transcribed: 5, settled: 5))
        store.addGap(LiveGap(track: .mic, startTime: 5, duration: 3, reason: .queueOverflow, isSilent: true))
        store.addGap(LiveGap(track: .mic, startTime: 6, duration: 4, reason: .captureGap))
        store.addGap(LiveGap(track: .mic, startTime: 10, duration: 1, reason: .queueOverflow, isSilent: true))
        store.addGap(LiveGap(track: .mic, startTime: 11, duration: 1, reason: .queueOverflow, isSilent: true))
        #expect(store.gaps == [
            LiveGap(track: .mic, startTime: 5, duration: 3, reason: .queueOverflow, isSilent: true),
            LiveGap(track: .mic, startTime: 8, duration: 2, reason: .captureGap),
            LiveGap(track: .mic, startTime: 10, duration: 2, reason: .queueOverflow, isSilent: true)
        ])
        #expect(store.settledThrough(.mic) == 12, "Gaps of either silence count as resolved")
    }

    @Test("A capture gap never joins a touching gap of another reason, so a device switch inside a pause does not mark recorded audio as unrecorded")
    func captureGapsJoinOnlyCaptureGaps() {
        var store = makeStore()
        store.apply(update(store, transcribed: 10, settled: 10))
        // The pump reports the device switch first; the heat pause around it ends later.
        store.addGap(LiveGap(track: .mic, startTime: 60, duration: 4, reason: .captureGap))
        store.addGap(LiveGap(track: .mic, startTime: 10, duration: 240, reason: .paused))
        store.addGap(LiveGap(track: .mic, startTime: 250, duration: 3, reason: .queueOverflow))

        #expect(store.gaps == [
            LiveGap(track: .mic, startTime: 10, duration: 50, reason: .paused),
            LiveGap(track: .mic, startTime: 60, duration: 4, reason: .captureGap),
            LiveGap(track: .mic, startTime: 64, duration: 186, reason: .paused),
            LiveGap(track: .mic, startTime: 250, duration: 3, reason: .queueOverflow)
        ])
        #expect(store.settledThrough(.mic) == 253, "touching gaps still chain for the settled time")
    }

    @Test("Recorded gaps count as resolved for the settled and transcribed times")
    func settledThroughExtendsThroughGaps() {
        var store = makeStore()
        store.apply(update(store, transcribed: 6, settled: 5))
        store.addGap(LiveGap(track: .mic, startTime: 5, duration: 3, reason: .captureGap))
        store.addGap(LiveGap(track: .mic, startTime: 8, duration: 1, reason: .queueOverflow))
        store.addGap(LiveGap(track: .mic, startTime: 12, duration: 1, reason: .captureGap))
        #expect(store.settledThrough(.mic) == 9)
        #expect(store.transcribedThrough(.mic) == 9)
    }

    @Test("A new generation drops the old generation's tails and accepts its own updates")
    func newGenerationDropsOldTails() {
        var store = makeStore()
        let row = LiveRow(track: .mic, startTime: 1, endTime: 3, settledText: "Hello", tailText: " wor")
        let tailOnly = LiveRow(track: .system, startTime: 2, endTime: 3, tailText: "maybe")
        store.apply(update(store, revision: 9, rows: [row]))
        store.apply(update(store, .system, revision: 9, rows: [tailOnly]))
        store.beginGeneration(2)
        #expect(store.rows.map(\.tailText) == ["", ""])
        #expect(!store.rows.contains { !$0.isClosed })
        #expect(store.snapshot(includeTail: true).rows.map(\.id) == [row.id], "a row left with no text is not shown")
        let first = update(store, revision: 1)
        let firstApplied = store.apply(first)
        #expect(firstApplied, "revisions start again with the generation")
    }

    @Test("A snapshot without the tail ends a row with a tail at its track's settled time")
    func snapshotClampsOpenRowEndWithoutTail() throws {
        var store = makeStore()
        let row = LiveRow(track: .mic, startTime: 1, endTime: 6, settledText: "Hello", tailText: " there friend")
        store.recordCapture([.mic: 6])
        store.apply(update(store, rows: [row], transcribed: 6, settled: 3))
        let settled = try #require(store.snapshot(includeTail: false).rows.first)
        #expect(settled.tailText.isEmpty && settled.endTime == 3)
        let full = try #require(store.snapshot(includeTail: true).rows.first)
        #expect(full == row)
    }
}

@Suite("PowerPolicy")
@MainActor
struct PowerPolicyTests {
    @Test("Low Power Mode doubles the update interval")
    func lowPowerDoublesInterval() async throws {
        let source = FakePowerSource()
        let decisions = DecisionLog()
        let policy = PowerPolicy(source: source) { decisions.values.append($0) }
        #expect(policy.decision.intervalMultiplier == 1)

        source.send(PowerState(isLowPowerModeEnabled: true))
        try await waitUntil("the low-power decision") { !decisions.values.isEmpty }
        #expect(policy.decision.intervalMultiplier == 2)
        #expect(!policy.decision.isPaused)
    }

    @Test("Serious heat pauses; nominal resumes")
    func seriousHeatPausesAndNominalResumes() async throws {
        let source = FakePowerSource(PowerState(thermalState: .fair))
        let decisions = DecisionLog()
        let policy = PowerPolicy(source: source) { decisions.values.append($0) }
        #expect(!policy.decision.isPaused)

        source.send(PowerState(thermalState: .serious))
        try await waitUntil("the pause") { decisions.values.count == 1 }
        #expect(policy.decision.isPaused)
        source.send(PowerState(thermalState: .critical))
        source.send(PowerState(thermalState: .nominal))
        try await waitUntil("the resume") { decisions.values.count == 2 }
        #expect(!policy.decision.isPaused, "critical is no change from serious; nominal resumes")
    }
}

@MainActor
private final class DecisionLog {
    var values: [PowerPolicy.Decision] = []
}
