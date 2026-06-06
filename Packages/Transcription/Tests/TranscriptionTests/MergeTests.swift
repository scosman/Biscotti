import Foundation
import Testing
@testable import Transcription

// Note: The bundled fixture WAVs (mic_fixture.wav, system_fixture.wav) in Fixtures/ are
// scaffolding for a later phase that will add file-loading integration tests (loading real
// WAV files through AudioProcessor and merging them). The current tests exercise the merge
// logic with in-memory float arrays, which does not require audio files.

@Suite("AudioMerger")
struct MergeTests {
    // MARK: - Two-stream merge

    @Test("Two equal-length mono arrays merge to one of the same length")
    func twoStreamsMergeToSameLength() throws {
        let mic: [Float] = [0.5, 0.3, -0.2, 0.1]
        let system: [Float] = [0.1, 0.2, 0.4, -0.3]

        let result = try AudioMerger.merge(mic: mic, system: system)

        #expect(result.samples.count == 4)
    }

    @Test("Merged samples are the sum of inputs (no clipping needed)")
    func mergedSamplesAreSummed() throws {
        let mic: [Float] = [0.2, 0.3]
        let system: [Float] = [0.1, 0.1]

        let result = try AudioMerger.merge(mic: mic, system: system)

        // Sum stays <= 1.0, so no normalization
        #expect(abs(result.samples[0] - 0.3) < 0.0001)
        #expect(abs(result.samples[1] - 0.4) < 0.0001)
    }

    @Test("Merged samples are normalized when sum exceeds 1.0")
    func mergedSamplesNormalizedOnClip() throws {
        let mic: [Float] = [0.8, -0.8]
        let system: [Float] = [0.8, -0.8]

        let result = try AudioMerger.merge(mic: mic, system: system)

        // Sum would be [1.6, -1.6], peak=1.6, scale=1/1.6=0.625
        // Result: [1.0, -1.0]
        #expect(abs(result.samples[0] - 1.0) < 0.0001)
        #expect(abs(result.samples[1] - -1.0) < 0.0001)
    }

    @Test("Unequal-length streams: output length is the longer")
    func unequalLengthStreams() throws {
        let mic: [Float] = [0.5, 0.3, 0.1]
        let system: [Float] = [0.2]

        let result = try AudioMerger.merge(mic: mic, system: system)

        #expect(result.samples.count == 3)
    }

    @Test("Labels mark 'both' for overlap region and tail for longer stream")
    func labelsForTwoStreams() throws {
        let mic: [Float] = [0.5, 0.3, 0.1]
        let system: [Float] = [0.2]

        let result = try AudioMerger.merge(mic: mic, system: system)

        #expect(result.labels.count == 2)
        #expect(result.labels[0].label == .both)
        #expect(result.labels[0].startSample == 0)
        #expect(result.labels[0].endSample == 1)
        #expect(result.labels[1].label == .mic)
        #expect(result.labels[1].startSample == 1)
        #expect(result.labels[1].endSample == 3)
    }

    @Test("Labels for equal-length streams show all 'both'")
    func labelsForEqualLengthStreams() throws {
        let mic: [Float] = [0.5, 0.3]
        let system: [Float] = [0.2, 0.1]

        let result = try AudioMerger.merge(mic: mic, system: system)

        #expect(result.labels.count == 1)
        #expect(result.labels[0].label == .both)
        #expect(result.labels[0].startSample == 0)
        #expect(result.labels[0].endSample == 2)
    }

    @Test("System longer than mic labels tail as system")
    func systemLongerThanMic() throws {
        let mic: [Float] = [0.5]
        let system: [Float] = [0.2, 0.1, 0.3]

        let result = try AudioMerger.merge(mic: mic, system: system)

        #expect(result.labels.count == 2)
        #expect(result.labels[1].label == .system)
        #expect(result.labels[1].startSample == 1)
        #expect(result.labels[1].endSample == 3)
    }

    // MARK: - Single-stream inputs

    @Test("Mic only: output is the mic samples with mic label")
    func micOnlyPassthrough() throws {
        let mic: [Float] = [0.5, 0.3, -0.2]

        let result = try AudioMerger.merge(mic: mic, system: nil)

        #expect(result.samples == mic)
        #expect(result.labels.count == 1)
        #expect(result.labels[0].label == .mic)
        #expect(result.labels[0].startSample == 0)
        #expect(result.labels[0].endSample == 3)
    }

    @Test("System only: output is the system samples with system label")
    func systemOnlyPassthrough() throws {
        let system: [Float] = [0.1, 0.4]

        let result = try AudioMerger.merge(mic: nil, system: system)

        #expect(result.samples == system)
        #expect(result.labels.count == 1)
        #expect(result.labels[0].label == .system)
    }

    // MARK: - Merged (pre-merged) input

    @Test("wrapMerged wraps samples with merged label")
    func wrapMergedSamples() throws {
        let samples: [Float] = [0.1, 0.2, 0.3]

        let result = try AudioMerger.wrapMerged(samples)

        #expect(result.samples == samples)
        #expect(result.labels.count == 1)
        #expect(result.labels[0].label == .merged)
    }

    @Test("wrapMerged throws invalidInput on empty samples")
    func wrapMergedEmptyThrows() {
        #expect(throws: TranscriptionError.self) {
            _ = try AudioMerger.wrapMerged([])
        }
    }

    // MARK: - Invalid input

    @Test("Both nil throws invalidInput")
    func bothNilThrows() {
        #expect(throws: TranscriptionError.self) {
            _ = try AudioMerger.merge(mic: nil, system: nil)
        }
    }

    @Test("Both empty throws invalidInput")
    func bothEmptyThrows() {
        #expect(throws: TranscriptionError.self) {
            _ = try AudioMerger.merge(mic: [], system: [])
        }
    }

    @Test("Mic nil and system empty throws invalidInput")
    func micNilSystemEmptyThrows() {
        #expect(throws: TranscriptionError.self) {
            _ = try AudioMerger.merge(mic: nil, system: [])
        }
    }

    @Test("Mic empty and system nil throws invalidInput")
    func micEmptySystemNilThrows() {
        #expect(throws: TranscriptionError.self) {
            _ = try AudioMerger.merge(mic: [], system: nil)
        }
    }

    @Test("Non-empty mic with empty system uses mic only")
    func nonEmptyMicEmptySystem() throws {
        let mic: [Float] = [0.5, 0.3]

        let result = try AudioMerger.merge(mic: mic, system: [])

        #expect(result.samples == mic)
        #expect(result.labels[0].label == .mic)
    }

    // MARK: - Duration

    @Test("Duration calculated from sample count at 16 kHz")
    func durationCalculation() throws {
        // 16000 samples = 1.0 second at 16 kHz
        let samples = [Float](repeating: 0.1, count: 16000)

        let result = try AudioMerger.merge(mic: samples, system: nil)

        #expect(abs(result.duration - 1.0) < 0.0001)
    }

    @Test("Duration of 1600 samples = 0.1 seconds")
    func shortDuration() throws {
        let samples = [Float](repeating: 0.1, count: 1600)

        let result = try AudioMerger.merge(mic: samples, system: nil)

        #expect(abs(result.duration - 0.1) < 0.0001)
    }
}
