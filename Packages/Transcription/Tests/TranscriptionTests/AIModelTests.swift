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

// TODO: These tests rely on WhisperKit's inline auto-download during processAudio,
// which doesn't cleanly recover from a partial/.incomplete download (caused a
// first-run failure on hardware). Ideally the test should ensure a clean model
// download itself (e.g. via ensureModelsDownloaded or clearing partials) before
// running inference.

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

        // Diarization structure: 5 chunks, 3 speakers, correct interleaving
        let diarEval = DiarizationGroundTruth.evaluate(result)
        #expect(diarEval.passed, "\(diarEval.detail)")

        // Transcript accuracy (speaker-agnostic): full-text Levenshtein within tolerance
        let accEval = TranscriptAccuracyGroundTruth.evaluate(result)
        #expect(accEval.passed, "\(accEval.detail)")

        // No hallucination: no segment endTime exceeds the actual audio duration
        let duration = try audioDuration(mic)
        let maxEnd = result.segments.map(\.endTime).max() ?? 0
        #expect(
            maxEnd <= duration + 0.001,
            "Hallucination detected: segment endTime \(maxEnd) exceeds audio duration \(duration)"
        )
    }

    /// Custom-vocab test disabled — WhisperKit's promptTokens API silently
    /// blanks the entire transcript for certain term combinations, even
    /// all-lowercase, even with the non-turbo v20240930_626MB model (Gotcha #16).
    /// Blocked on upstream fix:
    ///   https://github.com/argmaxinc/argmax-oss-swift/issues/489
    ///   https://github.com/argmaxinc/argmax-oss-swift/pull/428
    /// Re-enable once the SDK issue is resolved or a workaround is in place.
    @Test(
        "Custom-vocab word match",
        .tags(.aiModel),
        .enabled(if: AITestGate.isEnabled),
        .disabled("WhisperKit promptTokens blanks transcript — blocked on SDK fix")
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
