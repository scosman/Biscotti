import AVFoundation
import Testing
import Transcription

// MARK: - Tag + gate

extension Tag {
    @Tag static var aiModel: Self
}

/// Gate for AI model tests. Only enabled when `BISCOTTI_RUN_AI_TESTS=1`.
/// Under plain `make test` the env var is unset, so these tests are skipped
/// (no model download, no inference).
enum AITestGate {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["BISCOTTI_RUN_AI_TESTS"] == "1"
    }
}

// MARK: - Audio duration helper

/// Returns the duration of an audio file in seconds, for the no-hallucination check.
private func audioDuration(_ url: URL) throws -> TimeInterval {
    let file = try AVAudioFile(forReading: url)
    let frames = AVAudioFrameCount(file.length)
    let sampleRate = file.processingFormat.sampleRate
    guard sampleRate > 0 else {
        throw AudioDurationError.invalidSampleRate
    }
    return Double(frames) / sampleRate
}

private enum AudioDurationError: Error, CustomStringConvertible {
    case invalidSampleRate

    var description: String {
        "Audio file has invalid sample rate (0)"
    }
}

// MARK: - AI model tests

@Suite("AI model tests")
struct AIModelTestSuite {
    @Test(
        "Diarization + transcript accuracy (3-speaker clip)",
        .tags(.aiModel),
        .enabled(if: AITestGate.isEnabled)
    )
    func diarizationAndAccuracy() async throws {
        let mic = try #require(Bundle.module.url(
            forResource: "mic_fixture", withExtension: "wav", subdirectory: "Fixtures"
        ))
        let sys = try #require(Bundle.module.url(
            forResource: "system_fixture", withExtension: "wav", subdirectory: "Fixtures"
        ))

        let result = try await Transcriber(backend: .inProcess).processAudio(
            mic: mic, system: sys
        )

        // Diarization: 5 chunks, 3 speakers, correct interleaving, text within tolerance
        let eval = DiarizationGroundTruth.evaluate(result)
        #expect(eval.passed, "\(eval.detail)")

        // No hallucination: no segment endTime exceeds the actual audio duration
        let duration = try audioDuration(mic)
        let maxEnd = result.segments.map(\.endTime).max() ?? 0
        #expect(
            maxEnd <= duration + 0.001,
            "Hallucination detected: segment endTime \(maxEnd) exceeds audio duration \(duration)"
        )
    }

    @Test(
        "Custom-vocab word match",
        .tags(.aiModel),
        .enabled(if: AITestGate.isEnabled)
    )
    func customVocabWordMatch() async throws {
        let clip = try #require(Bundle.module.url(
            forResource: "custom_vocab_test", withExtension: "aac", subdirectory: "Fixtures"
        ))

        let result = try await Transcriber(backend: .inProcess).processAudio(
            mic: clip, system: clip, customVocabulary: GroundTruth.vocabTerms
        )

        let eval = VocabGroundTruth.evaluate(result)
        #expect(eval.passed, "\(eval.detail)")
    }
}
