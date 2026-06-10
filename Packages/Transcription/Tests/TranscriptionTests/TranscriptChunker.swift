import Foundation
import Transcription

/// A merged speaker chunk: maximal run of consecutive segments with the
/// same `speakerID`, ordered by start time.
struct TranscriptChunk: Equatable {
    let speakerID: Int?
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

/// Merges a `TranscriptResult`'s segments into speaker chunks.
///
/// Segments are sorted by `startTime`. Adjacent segments sharing the same
/// `speakerID` (including `nil == nil`) are merged: texts joined by a
/// single space, start = min, end = max.
enum TranscriptChunker {
    static func chunks(from result: TranscriptResult) -> [TranscriptChunk] {
        let sorted = result.segments.sorted { $0.startTime < $1.startTime }
        guard let first = sorted.first else { return [] }

        var chunks: [TranscriptChunk] = []
        var currentSpeaker = first.speakerID
        var currentTexts = [first.text]
        var currentStart = first.startTime
        var currentEnd = first.endTime

        for segment in sorted.dropFirst() {
            if segment.speakerID == currentSpeaker {
                currentTexts.append(segment.text)
                currentEnd = max(currentEnd, segment.endTime)
            } else {
                chunks.append(TranscriptChunk(
                    speakerID: currentSpeaker,
                    text: currentTexts.joined(separator: " "),
                    start: currentStart,
                    end: currentEnd
                ))
                currentSpeaker = segment.speakerID
                currentTexts = [segment.text]
                currentStart = segment.startTime
                currentEnd = segment.endTime
            }
        }

        // Flush the last chunk
        chunks.append(TranscriptChunk(
            speakerID: currentSpeaker,
            text: currentTexts.joined(separator: " "),
            start: currentStart,
            end: currentEnd
        ))

        return chunks
    }
}
