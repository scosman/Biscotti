import Foundation
import SpeakerKit

/// A single diarization time range for one speaker.
public struct DiarizedSpan: Sendable, Codable, Equatable {
    public let speakerID: Int
    public let start: TimeInterval
    public let end: TimeInterval

    public init(speakerID: Int, start: TimeInterval, end: TimeInterval) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
    }
}

/// Computes total speaking time per diarization speaker.
enum SpeakerDurations {
    /// Sums the duration of each span, grouped by speaker ID.
    static func compute(_ spans: [DiarizedSpan]) -> [Int: TimeInterval] {
        var totals: [Int: TimeInterval] = [:]
        for span in spans {
            let duration = max(0, span.end - span.start)
            totals[span.speakerID, default: 0] += duration
        }
        return totals
    }

    /// Extracts diarized spans from a SpeakerKit diarization result.
    /// Segments with a nil `speaker.speakerId` are skipped.
    static func spans(from diarization: DiarizationResult) -> [DiarizedSpan] {
        diarization.segments.compactMap { segment -> DiarizedSpan? in
            guard let speakerID = segment.speaker.speakerId else { return nil }
            return DiarizedSpan(
                speakerID: speakerID,
                start: TimeInterval(segment.startTime),
                end: TimeInterval(segment.endTime)
            )
        }
    }
}
