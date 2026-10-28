import AudioCapture
import BiscottiTestSupport
import Foundation
import LiveTranscriptModel
import Testing
@testable import LiveTranscriptionService

/// Collects what a `LivePumpCore` produces.
private final class PumpOutput {
    var chunks: [LiveAudioChunk] = []
    var gaps: [LiveGap] = []
    /// Chunk numbers (counted from 1 per call to the sink) to refuse.
    var refused: Set<Int> = []
    /// While false, the sink refuses everything.
    var accepts = true
    private var offers = 0

    func makeCore(discardBefore: TimeInterval = 0) -> LivePumpCore {
        LivePumpCore(
            discardBefore: discardBefore,
            sink: { [self] chunk in
                offers += 1
                guard accepts, !refused.contains(offers) else { return false }
                chunks.append(chunk)
                return true
            },
            onGap: { [self] in gaps.append($0) }
        )
    }

    func chunks(on track: LiveTrack) -> [LiveAudioChunk] {
        chunks.filter { $0.track == track }
    }
}

private extension LivePumpCore {
    func feed(_ samples: [Float], rate: Double, channels: Int = 1, at time: TimeInterval, on track: LiveTrack = .mic) {
        samples.withUnsafeBufferPointer {
            process(LiveAudioBlock(startTime: time, kind: .samples($0, sampleRate: rate, channelCount: channels)), on: track)
        }
    }

    /// `seconds` of mono audio in blocks of `blockSeconds`, from `start`.
    func feedBlocks(
        seconds: TimeInterval,
        blockSeconds: TimeInterval = 0.1,
        rate: Double,
        from start: TimeInterval = 0,
        on track: LiveTrack = .mic,
        value: (Int) -> Float = { sin(Float($0) * 0.0577) * 0.5 }
    ) {
        let frames = Int((blockSeconds * rate).rounded())
        for block in 0 ..< Int((seconds / blockSeconds).rounded()) {
            feed((0 ..< frames).map { value(block * frames + $0) }, rate: rate, at: start + Double(block) * blockSeconds, on: track)
        }
    }

    func feedGap(at time: TimeInterval, duration: TimeInterval, kind: LiveAudioGapKind, on track: LiveTrack = .mic) {
        process(LiveAudioBlock(startTime: time, kind: .gap(duration: duration, kind: kind)), on: track)
    }

    func feedEnd(at time: TimeInterval, on track: LiveTrack = .mic) {
        process(LiveAudioBlock(startTime: time, kind: .end), on: track)
    }
}

@Suite("LiveAudioPump")
struct LiveAudioPumpTests {
    @Test("24 kHz mic audio becomes 250 ms chunks of 16 kHz audio at exact times")
    func resamples24kMicTo16kWithExactTimes() {
        let output = PumpOutput()
        let core = output.makeCore()
        core.feedBlocks(seconds: 1, rate: 24000)
        core.feedEnd(at: 1)

        let chunks = output.chunks(on: .mic)
        #expect(chunks.prefix(4).map(\.startTime) == [0, 0.25, 0.5, 0.75])
        #expect(chunks.prefix(3).allSatisfy { $0.samples.count == LivePumpCore.chunkSamples })
        let total = chunks.reduce(0) { $0 + $1.samples.count }
        #expect(abs(total - 16000) <= 64, "1 s at 16 kHz, give or take the resampler's edges")
        #expect(!chunks.contains { $0.isDiscontinuity })
        #expect(output.gaps.isEmpty)
    }

    @Test("48 kHz stereo system audio is downmixed by averaging the channels")
    func resamples48kStereoSystemByDownmixing() throws {
        let output = PumpOutput()
        let core = output.makeCore()
        // Left 0.4 and right 0.2: the average is 0.3; a sum would be 0.6.
        let frames = 4800
        let stereo = (0 ..< frames).flatMap { _ in [Float(0.4), Float(0.2)] }
        for block in 0 ..< 5 {
            core.feed(stereo, rate: 48000, channels: 2, at: Double(block) * 0.1, on: .system)
        }
        core.feedEnd(at: 0.5, on: .system)

        let samples = output.chunks(on: .system).flatMap(\.samples)
        #expect(abs(samples.count - 8000) <= 64)
        let middle = try #require(samples.dropFirst(1000).dropLast(1000).sorted().dropFirst(3000).first)
        #expect(abs(middle - 0.3) < 0.01)
        #expect(output.chunks(on: .system).first?.startTime == 0)
    }

    @Test("A new source rate builds a new converter and continues the run without a time jump")
    func formatChangeRebuildsConverterWithoutTimeJump() {
        let output = PumpOutput()
        let core = output.makeCore()
        core.feedBlocks(seconds: 0.5, rate: 24000)
        core.feedBlocks(seconds: 0.5, rate: 48000, from: 0.5)
        core.feedEnd(at: 1)

        let chunks = output.chunks(on: .mic)
        #expect(chunks.prefix(4).map(\.startTime) == [0, 0.25, 0.5, 0.75])
        #expect(abs(chunks.reduce(0) { $0 + $1.samples.count } - 16000) <= 96)
        #expect(output.gaps.isEmpty)
        #expect(!chunks.contains { $0.isDiscontinuity })
    }

    @Test("A block over 20 ms late is a capture gap, and the chunk after it is discontinuous")
    func lateBlockEmitsGapAndDiscontinuity() throws {
        let output = PumpOutput()
        let core = output.makeCore()
        core.feedBlocks(seconds: 0.5, rate: 16000)
        // 10 ms late: within the tolerance, still one run.
        core.feedBlocks(seconds: 0.2, rate: 16000, from: 0.51)
        core.feedBlocks(seconds: 0.4, rate: 16000, from: 1.0)
        core.feedEnd(at: 1.4)

        let gap = try #require(output.gaps.first)
        #expect(output.gaps.count == 1)
        #expect(gap.track == .mic && gap.reason == .captureGap)
        #expect(abs(gap.startTime - 0.71) < 1e-9 && abs(gap.duration - 0.29) < 1e-9)
        let afterGap = try #require(output.chunks.first { $0.startTime >= 1.0 })
        #expect(afterGap.startTime == 1.0 && afterGap.isDiscontinuity)
        #expect(output.chunks.filter(\.isDiscontinuity).count == 1)
        // The run before the gap ends with its partial chunk.
        #expect(output.chunks.contains { abs($0.startTime - 0.5) < 1e-9 && $0.samples.count == 3200 })
    }

    @Test("A block that starts before the previous one ended is trimmed to its new audio")
    func overlappingBlockIsTrimmed() {
        let output = PumpOutput()
        let core = output.makeCore()
        core.feedBlocks(seconds: 0.5, blockSeconds: 0.5, rate: 16000)
        core.feed([Float](repeating: 0.1, count: 3200), rate: 16000, at: 0.4)
        core.feed([Float](repeating: 0.1, count: 1600), rate: 16000, at: 0.1)
        core.feedEnd(at: 0.6)

        #expect(output.chunks.reduce(0) { $0 + $1.samples.count } == 9600)
        #expect(output.gaps.isEmpty)
        #expect(output.chunks.map(\.startTime) == [0, 0.25, 0.5])
    }

    @Test("The system track's leading silence moves its start without a visible gap")
    func notStartedGapShiftsStartWithoutVisibleGap() throws {
        let output = PumpOutput()
        let core = output.makeCore()
        core.feedGap(at: 0, duration: 1.5, kind: .notStarted, on: .system)
        core.feedBlocks(seconds: 0.5, rate: 16000, from: 1.5, on: .system)
        core.feedEnd(at: 2, on: .system)

        #expect(output.gaps.isEmpty)
        let first = try #require(output.chunks.first)
        #expect(first.startTime == 1.5 && !first.isDiscontinuity)
        #expect(abs((core.capturedThrough[.system] ?? 0) - 2) < 1e-9)
    }

    @Test("A start mid-recording drops earlier audio; a gap after the start still counts")
    func discardBeforeDropsEarlierAudio() throws {
        let output = PumpOutput()
        let core = output.makeCore(discardBefore: 2)
        core.feedBlocks(seconds: 2.5, blockSeconds: 0.5, rate: 16000)
        core.feedGap(at: 2.5, duration: 1, kind: .overflow)
        core.feedBlocks(seconds: 0.5, rate: 16000, from: 3.5)
        core.feedEnd(at: 4)

        let first = try #require(output.chunks.first)
        #expect(first.startTime == 2 && !first.isDiscontinuity)
        #expect(output.gaps == [LiveGap(track: .mic, startTime: 2.5, duration: 1, reason: .queueOverflow)])
        #expect(output.chunks.first { $0.startTime >= 3.5 }?.isDiscontinuity == true)
    }

    @Test("The tap's overflow from before a start mid-recording is not a gap at the start marker")
    func overflowBeforeTheStartIsNotAGap() throws {
        let output = PumpOutput()
        let core = output.makeCore(discardBefore: 10)
        // The queue filled at 4 s with nothing draining and dropped audio
        // until just after the start.
        core.feedBlocks(seconds: 4, blockSeconds: 0.5, rate: 16000)
        core.feedGap(at: 4, duration: 6.3, kind: .overflow)
        core.feedBlocks(seconds: 1, rate: 16000, from: 10.3)
        core.feedEnd(at: 11.3)

        #expect(output.gaps.isEmpty)
        let first = try #require(output.chunks.first)
        #expect(first.startTime == 10.3 && !first.isDiscontinuity)
        #expect(!output.chunks.contains { $0.isDiscontinuity })
    }

    @Test("Overflow reaching more than a second past a start mid-recording is a gap from there on")
    func overflowFarPastTheStartIsAGap() throws {
        let output = PumpOutput()
        let core = output.makeCore(discardBefore: 10)
        core.feedBlocks(seconds: 4, blockSeconds: 0.5, rate: 16000)
        core.feedGap(at: 4, duration: 8.5, kind: .overflow)
        core.feedBlocks(seconds: 1, rate: 16000, from: 12.5)
        core.feedEnd(at: 13.5)

        let gap = try #require(output.gaps.first)
        #expect(output.gaps.count == 1)
        #expect(gap.reason == .queueOverflow && gap.startTime == 11)
        #expect(abs(gap.duration - 1.5) < 1e-9)
        #expect(output.chunks.first?.startTime == 12.5)
        #expect(output.chunks.first?.isDiscontinuity == true)
    }

    @Test("A chunk the engine cannot take waits and goes first once the engine takes chunks again")
    func refusedChunkWaitsAndArrivesInOrder() {
        let output = PumpOutput()
        output.refused = [2]
        let core = output.makeCore()
        core.feedBlocks(seconds: 1, rate: 16000)
        core.feedEnd(at: 1)
        core.feedEnd(at: 1, on: .system)

        #expect(output.gaps.isEmpty)
        #expect(output.chunks.map(\.startTime) == [0, 0.25, 0.5, 0.75])
        #expect(!output.chunks.contains { $0.isDiscontinuity })
        #expect(core.isEnded)
    }

    @Test("Dropped silence is a silent gap; dropped speech is not")
    func droppedAudioKnowsWhetherItWasSilent() {
        let output = PumpOutput()
        output.accepts = false
        let core = output.makeCore()
        // 2 s of silence, then speech, until 2 s of speech has been dropped too.
        core.feedBlocks(seconds: 2, blockSeconds: 0.5, rate: 16000, value: { _ in 0 })
        core.feedBlocks(seconds: LivePumpCore.retention + 2, blockSeconds: 0.5, rate: 16000, from: 2)

        let silent = output.gaps.filter(\.isSilent)
        let spoken = output.gaps.filter { !$0.isSilent }
        #expect(abs(silent.reduce(0) { $0 + $1.duration } - 2) < 1e-9)
        #expect(silent.allSatisfy { $0.endTime <= 2 + 1e-9 })
        #expect(abs(spoken.reduce(0) { $0 + $1.duration } - 2) < 1e-9)
        #expect(spoken.allSatisfy { $0.startTime >= 2 - 1e-9 })
    }

    @Test("Levels map −60…0 dBFS to 0…1 and follow the louder track")
    func levelsMapDecibelsToUnitRange() {
        #expect(LivePumpCore.level(ofRMS: 0) == 0)
        #expect(LivePumpCore.level(ofRMS: 0.0001) == 0)
        #expect(abs(LivePumpCore.level(ofRMS: 0.001) - 0) < 1e-6)
        #expect(abs(LivePumpCore.level(ofRMS: Float(pow(10.0, -30.0 / 20))) - 0.5) < 1e-4)
        #expect(LivePumpCore.level(ofRMS: 1) == 1)
        #expect(LivePumpCore.level(ofRMS: 2) == 1)

        let output = PumpOutput()
        let core = output.makeCore()
        core.feed([Float](repeating: 0.001, count: 1600), rate: 16000, at: 0, on: .mic)
        core.feed([Float](repeating: 0.1, count: 1600), rate: 16000, at: 0, on: .system)
        #expect(abs(core.takeLevel() - LivePumpCore.level(ofRMS: 0.1)) < 1e-4)
        #expect(core.takeLevel() == 0, "no new audio since the last reading")
    }

    @Test("The end flushes each track's last partial chunk, resampler remainder included")
    func endFlushesPartialChunks() throws {
        let output = PumpOutput()
        let core = output.makeCore()
        core.feedBlocks(seconds: 0.3, rate: 16000)
        core.feedBlocks(seconds: 0.3, rate: 24000, on: .system)
        #expect(output.chunks.count == 2, "one full chunk per track before the end")
        core.feedEnd(at: 0.3)
        core.feedEnd(at: 0.3, on: .system)

        #expect(core.isEnded)
        let micLast = try #require(output.chunks(on: .mic).last)
        #expect(micLast.startTime == 0.25 && micLast.samples.count == 800)
        let systemTotal = output.chunks(on: .system).reduce(0) { $0 + $1.samples.count }
        #expect(abs(systemTotal - 4800) <= 64)
    }

    @Test("The pump drains its tap on its queue, fills the pipe and ends after both tracks end")
    func pumpDrainsOnItsQueueAndEnds() async {
        let tap = ScriptedTap()
        let pipe = LiveChunkPipe()
        let pump = LiveAudioPump(source: tap, pipe: pipe, discardBefore: 0, interval: .milliseconds(5))
        tap.mic.pushTone(seconds: 0.5, from: 0)
        tap.system.pushGap(at: 0, duration: 0.2, kind: .notStarted)
        tap.system.pushTone(seconds: 0.3, from: 0.2)
        tap.end(at: 0.5)
        pump.start()

        var progress: [LiveTrack: TimeInterval] = [:]
        var ended = false
        for await event in pump.events {
            switch event {
            case let .progress(captured): progress = captured
            case .ended: ended = true
            case .gap, .level: break
            }
        }
        var chunks: [LiveAudioChunk] = []
        for track in pipe.tracks {
            for await chunk in pipe.chunks(of: track) {
                chunks.append(chunk)
            }
        }
        #expect(ended)
        #expect(abs((progress[.mic] ?? 0) - 0.5) < 1e-9)
        #expect(abs((progress[.system] ?? 0) - 0.5) < 1e-9)
        #expect(chunks.filter { $0.track == .mic }.map(\.startTime) == [0, 0.25])
        #expect(chunks.first { $0.track == .system }?.startTime == 0.2)
    }
}

@Suite("LivePumpCore backlog")
struct LivePumpCoreBacklogTests {
    @Test("Waiting audio is kept for 15 minutes in 16-bit samples; only older audio is lost, as gaps")
    func backlogBeyondRetentionBecomesGap() throws {
        let output = PumpOutput()
        output.accepts = false
        let core = output.makeCore()
        let total = LivePumpCore.retention + 5
        core.feedBlocks(seconds: total, blockSeconds: 5, rate: 16000)
        core.feedEnd(at: total)
        core.feedEnd(at: total, on: .system)
        #expect(!core.isEnded, "the waiting chunks still have to go")
        // 16-bit samples: 15 minutes of a track take under 30 MB.
        #expect(core.waitingByteCount == Int(LivePumpCore.retention * LiveAudioChunk.sampleRate) * 2)
        #expect(core.waitingByteCount < 30_000_000)

        output.accepts = true
        core.offerWaiting()
        #expect(core.isEnded)
        // One gap per dropped chunk; the store joins them.
        #expect(output.gaps.allSatisfy { $0.track == .mic && $0.reason == .queueOverflow && !$0.isSilent })
        #expect(output.gaps.first?.startTime == 0)
        #expect(abs(output.gaps.reduce(0) { $0 + $1.duration } - 5) < 1e-9)
        let first = try #require(output.chunks.first)
        #expect(first.startTime == 5 && first.isDiscontinuity)
        #expect(output.chunks.map(\.startTime) == (20 ..< Int(total * 4)).map { Double($0) * 0.25 })
        #expect(output.chunks.filter(\.isDiscontinuity).count == 1)
    }

    @Test("A waiting chunk comes back within one 16-bit step; a chunk taken at once is not converted")
    func waitingAudioKeepsItsSamples() throws {
        let output = PumpOutput()
        output.accepts = false
        let core = output.makeCore()
        let value: (Int) -> Float = { sin(Float($0) * 0.0577) * 0.5 }
        core.feedBlocks(seconds: 0.5, blockSeconds: 0.25, rate: 16000, value: value)
        output.accepts = true
        core.offerWaiting()
        core.feedBlocks(seconds: 0.25, blockSeconds: 0.25, rate: 16000, from: 0.5, value: { value(8000 + $0) })

        let samples = output.chunks.flatMap(\.samples)
        let expected = (0 ..< 12000).map(value)
        try #require(samples.count == expected.count)
        let waitingError = zip(samples.prefix(8000), expected.prefix(8000)).map { abs($0 - $1) }.max() ?? 0
        #expect(waitingError <= 0.5 / Float(Int16.max) + 1e-6)
        #expect(Array(samples.suffix(4000)) == Array(expected.suffix(4000)))
    }

    @Test("The pump knows how far each track's chunks reach, and the newest one with sound")
    func chunkExtentsTrackSound() throws {
        let output = PumpOutput()
        output.accepts = false
        let core = output.makeCore()
        core.feedBlocks(seconds: 1, blockSeconds: 0.25, rate: 16000)
        core.feedBlocks(seconds: 1, blockSeconds: 0.25, rate: 16000, from: 1, value: { _ in 0 })

        let extent = try #require(core.chunkExtents[.mic])
        #expect(extent == ChunkExtent(end: 2, voicedEnd: 1))
        #expect(core.chunkExtents[.system] == nil)
    }

    @Test("The pump's backlog is 15 minutes per track")
    func retentionIsThePumpBacklog() {
        #expect(LivePumpCore.retention == LiveAudioLimits.pumpBacklog)
        #expect(LivePumpCore.retention == 15 * 60)
    }
}

@Suite("LiveChunkPipe")
struct LiveChunkPipeTests {
    @Test("At most eight chunks per track wait or travel at once")
    func atMostEightPerTrack() {
        let pipe = LiveChunkPipe()
        let mic = LiveAudioChunk(track: .mic, startTime: 0, samples: [0])
        for _ in 0 ..< 8 {
            #expect(pipe.offer(mic))
        }
        #expect(!pipe.offer(mic))
        #expect(pipe.offer(LiveAudioChunk(track: .system, startTime: 0, samples: [0])), "each track has its own limit")
        pipe.release(.mic)
        #expect(pipe.offer(mic))
        pipe.finish()
        pipe.release(.mic)
        #expect(!pipe.offer(mic), "a finished pipe takes nothing")
    }

    @Test("Each track's chunks come in their own stream, in order")
    func eachTrackHasItsOwnStream() async {
        let pipe = LiveChunkPipe()
        let first = LiveAudioChunk(track: .mic, startTime: 0, samples: [0])
        let second = LiveAudioChunk(track: .mic, startTime: 0.25, samples: [0])
        let system = LiveAudioChunk(track: .system, startTime: 0, samples: [0])
        #expect(pipe.offer(first) && pipe.offer(system) && pipe.offer(second))
        #expect(!pipe.offer(LiveAudioChunk(track: .mixed, startTime: 0, samples: [0])), "a track the pipe does not carry")
        pipe.finish()

        var mic: [LiveAudioChunk] = []
        for await chunk in pipe.chunks(of: .mic) {
            mic.append(chunk)
        }
        var other: [LiveAudioChunk] = []
        for await chunk in pipe.chunks(of: .system) {
            other.append(chunk)
        }
        #expect(mic == [first, second])
        #expect(other == [system])
    }
}
