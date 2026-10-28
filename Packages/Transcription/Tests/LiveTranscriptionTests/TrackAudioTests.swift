import Foundation
import LiveTranscriptModel
import Testing
@testable import LiveTranscription

@Suite("TrackAudio")
struct TrackAudioTests {
    private func seconds(_ duration: TimeInterval) -> [Float] {
        Array(repeating: 0.1, count: Int(duration * LiveAudioChunk.sampleRate))
    }

    private func overflow(_ start: TimeInterval, _ duration: TimeInterval) -> LiveGap {
        LiveGap(track: .mic, startTime: start, duration: duration, reason: .queueOverflow)
    }

    /// A window of `decoded` seconds that a decode has covered, then `undecoded` seconds after it.
    private func audio(decoded: TimeInterval, undecoded: TimeInterval = 0) -> TrackAudio {
        var audio = TrackAudio(track: .mic, start: 0)
        audio.append(seconds(decoded))
        _ = audio.beginDecode()
        audio.append(seconds(undecoded))
        return audio
    }

    @Test("Trimming stops at the end of the decoded audio")
    func trimNeverRemovesUndecodedAudio() {
        var audio = audio(decoded: 2, undecoded: 1)

        audio.trimWindow(before: 0.5)
        #expect(audio.window.start == 0.5)

        audio.trimWindow(before: 10)
        #expect(audio.window.start == 2)
        #expect(audio.window.samples.count == 16000)
        #expect(audio.undecodedWindowAudio.count == 16000)
    }

    @Test("Overflow drops the undecoded audio right after the decoded part")
    func overflowDropsUndecodedAudioAfterTheDecodedPart() {
        var audio = audio(decoded: 10, undecoded: 40)

        #expect(audio.enforceRetentionLimit() == 5)
        #expect(audio.window.end == 10, "Audio a decode covers is kept")
        #expect(audio.runs.count == 2)
        #expect(audio.runs[1].start == 15)
        #expect(audio.runs[1].gapsBefore == [overflow(10, 5)])
        #expect(audio.retainedSampleCount == TrackAudio.retentionLimit)
    }

    @Test("Overflow continues into later runs and keeps their own gaps")
    func overflowContinuesIntoLaterRunsAndKeepsTheirGaps() {
        var audio = audio(decoded: 10, undecoded: 2)
        let capture = LiveGap(track: .mic, startTime: 12, duration: 2, reason: .captureGap)
        audio.startRun(at: 14, samples: seconds(40), gap: capture)

        #expect(audio.enforceRetentionLimit() == 7)
        #expect(audio.runs.count == 2)
        #expect(audio.runs[1].start == 19)
        #expect(audio.runs[1].gapsBefore == [overflow(10, 2), capture, overflow(14, 5)])
    }

    @Test("Overflow of silent audio is a silent gap; overflow of speech is not")
    func overflowGapKnowsWhetherItWasSilent() {
        var silent = TrackAudio(track: .mic, start: 0)
        silent.append(seconds(10))
        _ = silent.beginDecode()
        silent.append(Array(repeating: 0, count: Int(40 * LiveAudioChunk.sampleRate)))
        silent.enforceRetentionLimit()
        #expect(silent.runs[1].gapsBefore.map(\.isSilent) == [true])

        var spoken = audio(decoded: 10, undecoded: 40)
        spoken.enforceRetentionLimit()
        #expect(spoken.runs[1].gapsBefore.map(\.isSilent) == [false])
    }

    @Test("Silent and spoken overflow that follow each other stay separate gaps")
    func silentAndSpokenOverflowStaySeparate() {
        var audio = TrackAudio(track: .mic, start: 0)
        audio.append(seconds(43))
        _ = audio.beginDecode()
        audio.append(Array(repeating: 0, count: Int(2 * LiveAudioChunk.sampleRate)))
        // Each second of speech that arrives pushes out the oldest undecoded second.
        for _ in 0 ..< 3 {
            audio.append(seconds(1))
            audio.enforceRetentionLimit()
        }

        #expect(audio.runs[1].gapsBefore == [
            LiveGap(track: .mic, startTime: 43, duration: 2, reason: .queueOverflow, isSilent: true),
            overflow(45, 1)
        ])
    }

    @Test("Overflow that keeps happening grows one gap")
    func repeatedOverflowMergesIntoOneGap() {
        var audio = audio(decoded: 10, undecoded: 35)
        #expect(audio.enforceRetentionLimit() == 0)

        for _ in 0 ..< 4 {
            audio.append(seconds(0.25))
            audio.enforceRetentionLimit()
        }
        #expect(audio.runs.count == 2)
        #expect(audio.runs[1].gapsBefore == [overflow(10, 1)])
        #expect(audio.runs[1].start == 11)
    }
}
