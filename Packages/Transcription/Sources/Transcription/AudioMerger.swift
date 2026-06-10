import Foundation

/// Identifies which audio stream contributed to a merged sample range.
public enum StreamLabel: Sendable, Equatable {
    case mic
    case system
    case both
}

/// A range of samples in the merged output with its source label.
public struct LabeledRange: Sendable, Equatable {
    /// The start sample index (inclusive) in the merged array.
    public let startSample: Int

    /// The end sample index (exclusive) in the merged array.
    public let endSample: Int

    /// Which stream(s) this range came from.
    public let label: StreamLabel
}

/// Result of merging audio streams.
public struct MergeResult: Sendable, Equatable {
    /// The merged mono 16 kHz PCM samples.
    public let samples: [Float]

    /// Which source stream(s) contributed to each region of the output.
    public let labels: [LabeledRange]

    /// The duration of the merged audio in seconds at 16 kHz.
    public var duration: TimeInterval {
        TimeInterval(samples.count) / 16000.0
    }
}

/// Pure audio merge logic for combining mic + system streams.
///
/// Takes two mono 16 kHz `[Float]` arrays, sums and normalizes them to a
/// single merged array, and retains which sample ranges came from which stream.
/// The merge is unit-testable without any SDK dependency.
public enum AudioMerger {
    /// The expected sample rate for all input and output audio.
    public static let sampleRate: Double = 16000.0

    /// Merge two labeled audio streams into one mono output.
    ///
    /// **Precondition:** Both inputs must be mono 16 kHz PCM float arrays. Use
    /// `AudioProcessor.loadAudioAsFloatArray(fromPath:)` for file loading, which
    /// handles resampling and channel conversion automatically.
    ///
    /// - Parameters:
    ///   - mic: Mono 16 kHz samples from the microphone.
    ///   - system: Mono 16 kHz samples from system audio.
    /// - Returns: A `MergeResult` with the merged samples and label info.
    /// - Throws: `TranscriptionError.invalidInput` if both inputs have zero samples.
    public static func merge(
        mic: [Float],
        system: [Float]
    ) throws -> MergeResult {
        let hasMic = !mic.isEmpty
        let hasSystem = !system.isEmpty

        guard hasMic || hasSystem else {
            throw TranscriptionError.invalidInput(
                "At least one audio stream (mic or system) must contain non-zero samples"
            )
        }

        switch (hasMic, hasSystem) {
        case (true, true):
            return mergeTwoStreams(mic: mic, system: system)
        case (true, false):
            return MergeResult(
                samples: mic,
                labels: [LabeledRange(startSample: 0, endSample: mic.count, label: .mic)]
            )
        case (false, true):
            return MergeResult(
                samples: system,
                labels: [LabeledRange(startSample: 0, endSample: system.count, label: .system)]
            )
        case (false, false):
            // Already guarded above; unreachable
            throw TranscriptionError.invalidInput("No audio streams provided")
        }
    }

    // MARK: - Private

    private static func mergeTwoStreams(mic: [Float], system: [Float]) -> MergeResult {
        let outputLength = max(mic.count, system.count)
        var merged = [Float](repeating: 0, count: outputLength)

        // Sum the two streams, padding the shorter one with zeros.
        for sampleIndex in 0 ..< outputLength {
            let micValue: Float = sampleIndex < mic.count ? mic[sampleIndex] : 0
            let sysValue: Float = sampleIndex < system.count ? system[sampleIndex] : 0
            merged[sampleIndex] = micValue + sysValue
        }

        // Normalize to prevent clipping: scale so max(abs) <= 1.0.
        let peak = merged.reduce(Float(0)) { max($0, abs($1)) }
        if peak > 1.0 {
            let scale = 1.0 / peak
            for sampleIndex in 0 ..< merged.count {
                merged[sampleIndex] *= scale
            }
        }

        // Build labels describing which regions had contributions from which stream.
        let labels = buildLabels(micCount: mic.count, systemCount: system.count)

        return MergeResult(samples: merged, labels: labels)
    }

    private static func buildLabels(micCount: Int, systemCount: Int) -> [LabeledRange] {
        let shorter = min(micCount, systemCount)
        let longer = max(micCount, systemCount)
        var labels: [LabeledRange] = []

        if shorter > 0 {
            labels.append(LabeledRange(startSample: 0, endSample: shorter, label: .both))
        }

        if longer > shorter {
            let tailLabel: StreamLabel = micCount > systemCount ? .mic : .system
            labels.append(LabeledRange(startSample: shorter, endSample: longer, label: tailLabel))
        }

        return labels
    }
}
