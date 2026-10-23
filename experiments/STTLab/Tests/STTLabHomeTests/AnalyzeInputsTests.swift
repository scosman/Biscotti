import Foundation
import STTLabAnalysis
import STTLabCore
@testable import STTLabHome
import Testing
import WhisperKit

@Suite("AnalyzeInputs")
struct AnalyzeInputsTests {

    @Test("buildWhisperTranscript extracts words from segments")
    func whisperTranscriptBuilding() {
        let segment = TranscriptionSegment(
            id: 0, seek: 0,
            start: 0.0, end: 3.0,
            text: "hello world test",
            tokens: [],
            temperature: 0, avgLogprob: 0, compressionRatio: 0, noSpeechProb: 0,
            words: [
                WordTiming(word: " hello", tokens: [], start: 0.0, end: 0.5, probability: 0.9),
                WordTiming(word: " world", tokens: [], start: 0.5, end: 1.0, probability: 0.8),
                WordTiming(word: " test", tokens: [], start: 1.0, end: 1.5, probability: 0.7),
            ]
        )
        let result = TranscriptionResult(
            text: "hello world test",
            segments: [segment],
            language: "en",
            timings: TranscriptionTimings()
        )

        let (words, displayText) = AnalyzeInputs.buildWhisperTranscript([result])

        #expect(words.count == 3)
        #expect(words[0].text == "hello")
        #expect(words[1].text == "world")
        #expect(words[2].text == "test")
        #expect(words[0].start == 0.0)
        // Float -> Double loses precision; check approximate equality.
        #expect(abs(words[0].confidence! - 0.9) < 0.001)
        #expect(words[0].segmentIndex == 0)
        #expect(displayText == "hello world test")
    }

    @Test("buildWhisperTranscript skips special tokens")
    func whisperSkipsSpecialTokens() {
        let segment = TranscriptionSegment(
            id: 0, seek: 0,
            start: 0.0, end: 1.0,
            text: "hello",
            tokens: [],
            temperature: 0, avgLogprob: 0, compressionRatio: 0, noSpeechProb: 0,
            words: [
                WordTiming(word: "<|startoftranscript|>", tokens: [], start: 0.0, end: 0.1, probability: 1.0),
                WordTiming(word: " hello", tokens: [], start: 0.1, end: 0.5, probability: 0.9),
                WordTiming(word: "<|endoftext|>", tokens: [], start: 0.5, end: 0.6, probability: 1.0),
            ]
        )
        let result = TranscriptionResult(
            text: "hello",
            segments: [segment],
            language: "en",
            timings: TranscriptionTimings()
        )

        let (words, _) = AnalyzeInputs.buildWhisperTranscript([result])

        #expect(words.count == 1)
        #expect(words[0].text == "hello")
    }

    @Test("buildWhisperTranscript joins pieces with no leading space onto the previous word")
    func whisperJoinsContinuationPieces() {
        let segment = TranscriptionSegment(
            id: 0, seek: 0, start: 0, end: 3,
            text: " 5,000 AI-based", tokens: [],
            words: [
                WordTiming(word: " 5", tokens: [], start: 0.0, end: 0.4, probability: 0.9),
                WordTiming(word: ",000", tokens: [], start: 0.4, end: 0.8, probability: 0.9),
                WordTiming(word: " AI", tokens: [], start: 1.0, end: 1.3, probability: 0.9),
                WordTiming(word: "-based", tokens: [], start: 1.3, end: 1.8, probability: 0.9),
            ]
        )
        // A segment that starts with a no-space piece keeps it as its own word.
        let seg2 = TranscriptionSegment(
            id: 1, seek: 0, start: 3, end: 4,
            text: "%", tokens: [],
            words: [WordTiming(word: "%", tokens: [], start: 3.0, end: 3.2, probability: 0.9)]
        )
        let result = TranscriptionResult(
            text: "", segments: [segment, seg2], language: "en",
            timings: TranscriptionTimings()
        )

        let (words, displayText) = AnalyzeInputs.buildWhisperTranscript([result])

        #expect(words.map(\.text) == ["5,000", "AI-based", "%"])
        #expect(words[0].start == 0.0)
        #expect(abs((words[0].end ?? 0) - 0.8) < 0.001)
        #expect(abs((words[1].end ?? 0) - 1.8) < 0.001)
        #expect(displayText == "5,000 AI-based %")
    }

    @Test("buildWhisperTranscript increments segment counter across segments")
    func whisperSegmentCounter() {
        let seg1 = TranscriptionSegment(
            id: 0, seek: 0, start: 0, end: 1,
            text: "a", tokens: [],
            words: [WordTiming(word: " a", tokens: [], start: 0, end: 0.5, probability: 0.9)]
        )
        let seg2 = TranscriptionSegment(
            id: 1, seek: 0, start: 1, end: 2,
            text: "b", tokens: [],
            words: [WordTiming(word: " b", tokens: [], start: 1, end: 1.5, probability: 0.8)]
        )
        let result = TranscriptionResult(
            text: "a b",
            segments: [seg1, seg2],
            language: "en",
            timings: TranscriptionTimings()
        )

        let (words, _) = AnalyzeInputs.buildWhisperTranscript([result])

        #expect(words.count == 2)
        #expect(words[0].segmentIndex == 0)
        #expect(words[1].segmentIndex == 1)
    }

    @Test("buildReferenceTranscript reads chunk files sorted by startSample")
    func referenceTranscriptFromChunks() throws {
        // Create a temporary directory with mock chunk files.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-test-ref-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Chunk 2 (later in audio).
        let meta2 = ChunkMeta(
            chunkIndex: 1, startSample: 480000, endSample: 960000,
            startSeconds: 30.0, endSeconds: 60.0,
            requestMetadata: [:], httpStatus: 200, responseHeaders: [:],
            attempts: 1, latencySeconds: 2.0, requestedAt: Date()
        )
        try JSONFiles.write(meta2, to: tmpDir.appendingPathComponent("chunk_s480000_e960000.meta.json"))

        let response2 = """
        {"text": "chunk two", "words": [{"word": "chunk", "start": 0.0, "end": 0.5, "confidence": 0.9}, {"word": "two", "start": 0.5, "end": 1.0, "confidence": 0.8}]}
        """
        try response2.data(using: .utf8)!.write(to: tmpDir.appendingPathComponent("chunk_s480000_e960000.response.json"))

        // Chunk 1 (earlier in audio).
        let meta1 = ChunkMeta(
            chunkIndex: 0, startSample: 0, endSample: 480000,
            startSeconds: 0.0, endSeconds: 30.0,
            requestMetadata: [:], httpStatus: 200, responseHeaders: [:],
            attempts: 1, latencySeconds: 1.5, requestedAt: Date()
        )
        try JSONFiles.write(meta1, to: tmpDir.appendingPathComponent("chunk_s0_e480000.meta.json"))

        let response1 = """
        {"text": "chunk one", "words": [{"word": "chunk", "start": 0.0, "end": 0.5, "confidence": 0.95}, {"word": "one", "start": 0.5, "end": 1.0, "confidence": 0.85}]}
        """
        try response1.data(using: .utf8)!.write(to: tmpDir.appendingPathComponent("chunk_s0_e480000.response.json"))

        // Also write a status.json (not read by buildReferenceTranscript but needed for completeness).

        let meta = MeetingMeta(
            meetingID: "m01", durationSeconds: 60, sampleRate: 16000,
            speakerCount: 2, transcriptLanguage: "en", appleLocale: "en_US",
            audioFile: "audio.wav", audioSHA256: "abc"
        )

        let (words, displayText, hasWordTimes) = try AnalyzeInputs.buildReferenceTranscript(
            refDir: tmpDir, meta: meta
        )

        #expect(hasWordTimes == true)
        #expect(words.count == 4)
        // First two words should be from chunk 1 (startSample=0, offset=0).
        #expect(words[0].text == "chunk")
        #expect(words[0].start == 0.0)
        #expect(words[1].text == "one")
        #expect(words[1].start == 0.5)
        // Next two from chunk 2 (startSample=480000, offset=30s).
        #expect(words[2].text == "chunk")
        #expect(words[2].start == 30.0)  // 0.0 + 30.0 offset
        #expect(words[3].text == "two")
        #expect(words[3].start == 30.5)  // 0.5 + 30.0 offset
        #expect(displayText == "chunk one chunk two")
    }
}
