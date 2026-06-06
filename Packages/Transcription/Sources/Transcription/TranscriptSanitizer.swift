import Foundation

/// Mandatory post-processing pass over transcription output.
///
/// Addresses known Whisper end-of-audio hallucinations (segments timestamped
/// past the actual audio length) and unreliable segment-level confidence
/// (often reported as 0 by the free SDK v1.0.0).
public enum TranscriptSanitizer {
    /// Minimum average word probability to keep a trailing single-word segment.
    /// Below this threshold the segment is likely a hallucination.
    private static let trailingWordProbabilityThreshold: Float = 0.3

    /// Sanitizes a transcript result by:
    /// 1. Dropping segments whose start time is at or past `audioDuration`.
    /// 2. Clamping segments whose end time exceeds `audioDuration`.
    /// 3. Dropping trailing single-word segments with very low word probability.
    ///
    /// Confidence is derived from word-level `probability` only; segment-level
    /// `confidence` from the SDK is treated as unreliable.
    ///
    /// - Parameters:
    ///   - result: The raw transcript result from the engine.
    ///   - audioDuration: The actual duration of the audio in seconds.
    /// - Returns: A sanitized copy of the result.
    public static func sanitize(
        _ result: TranscriptResult,
        audioDuration: TimeInterval
    ) -> TranscriptResult {
        var segments = result.segments.compactMap { segment -> TranscriptSegment? in
            // Drop segments that start at or past the audio duration
            guard segment.startTime < audioDuration else { return nil }

            // Clamp end time to audio duration
            let clampedEnd = min(segment.endTime, audioDuration)

            if clampedEnd != segment.endTime {
                return TranscriptSegment(
                    id: segment.id,
                    speakerID: segment.speakerID,
                    speakerLabel: segment.speakerLabel,
                    startTime: segment.startTime,
                    endTime: clampedEnd,
                    text: segment.text,
                    confidence: segment.confidence,
                    noSpeechProbability: segment.noSpeechProbability,
                    words: segment.words
                )
            }

            return segment
        }

        // Drop trailing single-word segments with very low word probability
        while let last = segments.last {
            guard isLowConfidenceTrailingSingleWord(last) else { break }
            segments.removeLast()
        }

        return TranscriptResult(
            id: result.id,
            createdAt: result.createdAt,
            transcriptionMethodId: result.transcriptionMethodId,
            language: result.language,
            speakerCount: result.speakerCount,
            segments: segments,
            speakerEmbeddings: result.speakerEmbeddings,
            processingDuration: result.processingDuration
        )
    }

    /// Derives average confidence from word-level probabilities, ignoring
    /// the segment-level `confidence` field which is unreliable in WhisperKit
    /// v1.0.0 (often reported as 0).
    ///
    /// Callers should use this instead of `TranscriptSegment.confidence` to get
    /// a meaningful quality signal. Returns `nil` when the segment has no words.
    ///
    /// - Parameter segment: The segment whose word probabilities to average.
    /// - Returns: The mean word probability in `[0, 1]`, or `nil` if no words exist.
    public static func deriveConfidence(from segment: TranscriptSegment) -> Float? {
        guard let words = segment.words, !words.isEmpty else { return nil }
        let sum = words.reduce(Float(0)) { $0 + $1.probability }
        return sum / Float(words.count)
    }

    private static func isLowConfidenceTrailingSingleWord(
        _ segment: TranscriptSegment
    ) -> Bool {
        guard let words = segment.words, words.count == 1 else { return false }
        let avgProbability = words[0].probability
        return avgProbability < trailingWordProbabilityThreshold
    }
}
