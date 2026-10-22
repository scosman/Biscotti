import Foundation
import SpeakerKit
import STTLabAnalysis
import STTLabCore
@testable import STTLabHome
import Testing
import WhisperKit

@Suite("SpeakerAlignment")
struct SpeakerAlignmentTests {

    /// Build a minimal DiarizationResult with two speakers.
    /// Speaker 0 owns [0, 1.5)s, Speaker 1 owns [1.5, 3.0)s.
    static func makeDiarization() -> DiarizationResult {
        let frameRate: Float = 16000
        return DiarizationResult(
            speakerCount: 2,
            totalFrames: 48000,
            frameRate: frameRate,
            segments: [
                SpeakerSegment(
                    speaker: .speakerId(0),
                    startFrame: 0,
                    endFrame: 24000,
                    frameRate: frameRate
                ),
                SpeakerSegment(
                    speaker: .speakerId(1),
                    startFrame: 24000,
                    endFrame: 48000,
                    frameRate: frameRate
                ),
            ]
        )
    }

    @Test("Bridge produces correct TranscriptionResult structure")
    func bridgeStructure() {
        let transcript = EngineTranscript(
            engine: .apple,
            words: [
                EngineWord(text: "hello", start: 0.0, end: 0.5, confidence: 0.9, segmentIndex: 0),
                EngineWord(text: "world", start: 0.5, end: 1.0, confidence: 0.8, segmentIndex: 0),
                EngineWord(text: "foo", start: 1.5, end: 2.0, confidence: 0.7, segmentIndex: 1),
            ],
            displayText: "hello world foo"
        )

        let (results, dropped) = SpeakerAlignment.bridge(transcript)

        #expect(dropped == 0)
        #expect(results.count == 1)
        #expect(results[0].segments.count == 2)  // Two segment indices
        #expect(results[0].segments[0].words?.count == 2)  // "hello", "world"
        #expect(results[0].segments[1].words?.count == 1)  // "foo"
    }

    @Test("Bridge drops untimed words")
    func bridgeDropsUntimed() {
        let transcript = EngineTranscript(
            engine: .reference,
            words: [
                EngineWord(text: "hello", start: 0.0, end: 0.5, segmentIndex: 0),
                EngineWord(text: "untimed", segmentIndex: 0),  // No time
                EngineWord(text: "world", start: 1.0, end: 1.5, segmentIndex: 0),
            ],
            displayText: "hello untimed world",
            hasWordTimes: true
        )

        let (results, dropped) = SpeakerAlignment.bridge(transcript)

        #expect(dropped == 1)
        let wordCount = results[0].segments.flatMap { $0.words ?? [] }.count
        #expect(wordCount == 2)
    }

    @Test("Align assigns speakers from diarization")
    func alignAssignsSpeakers() {
        let diarization = Self.makeDiarization()

        // Words spanning both speakers.
        let transcript = EngineTranscript(
            engine: .apple,
            words: [
                EngineWord(text: "hello", start: 0.0, end: 0.5, confidence: 0.9, segmentIndex: 0),
                EngineWord(text: "world", start: 0.5, end: 1.0, confidence: 0.8, segmentIndex: 0),
                EngineWord(text: "bye", start: 1.5, end: 2.0, confidence: 0.7, segmentIndex: 1),
                EngineWord(text: "now", start: 2.0, end: 2.5, confidence: 0.6, segmentIndex: 1),
            ],
            displayText: "hello world bye now"
        )

        let aligned = SpeakerAlignment.align(
            transcript, whisperRaw: nil,
            diarization: diarization,
            audioDuration: 3.0
        )

        #expect(aligned.engine == .apple)
        #expect(!aligned.segments.isEmpty)
        #expect(!aligned.words.isEmpty)

        // Words in [0, 1.5) should get speaker 0.
        // Words in [1.5, 3.0) should get speaker 1.
        let earlyWords = aligned.words.filter {
            ($0.word.start ?? 0) < 1.5
        }
        let lateWords = aligned.words.filter {
            ($0.word.start ?? 0) >= 1.5
        }

        // At least the early words should have speaker 0.
        for w in earlyWords {
            #expect(w.speaker == 0)
        }
        // Late words should have speaker 1.
        for w in lateWords {
            #expect(w.speaker == 1)
        }
    }

    @Test("Align with Whisper raw results uses them directly")
    func alignWhisperRaw() {
        let diarization = Self.makeDiarization()

        let whisperSegment = TranscriptionSegment(
            id: 0, seek: 0,
            start: 0.0, end: 1.0,
            text: "hello world",
            tokens: [],
            temperature: 0, avgLogprob: 0, compressionRatio: 0, noSpeechProb: 0,
            words: [
                WordTiming(word: " hello", tokens: [], start: 0.0, end: 0.5, probability: 0.9),
                WordTiming(word: " world", tokens: [], start: 0.5, end: 1.0, probability: 0.8),
            ]
        )
        let rawResults = [TranscriptionResult(
            text: "hello world",
            segments: [whisperSegment],
            language: "en",
            timings: TranscriptionTimings()
        )]

        let transcript = EngineTranscript(
            engine: .whisper,
            words: [
                EngineWord(text: "hello", start: 0.0, end: 0.5, confidence: 0.9, segmentIndex: 0),
                EngineWord(text: "world", start: 0.5, end: 1.0, confidence: 0.8, segmentIndex: 0),
            ],
            displayText: "hello world"
        )

        let aligned = SpeakerAlignment.align(
            transcript, whisperRaw: rawResults,
            diarization: diarization,
            audioDuration: 3.0
        )

        #expect(aligned.engine == .whisper)
        #expect(aligned.droppedUntimedWords == 0)
        #expect(!aligned.words.isEmpty)
    }
}
