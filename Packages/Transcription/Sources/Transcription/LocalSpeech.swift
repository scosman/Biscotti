import Foundation

/// When voices are separated on the call audio alone, the person recording
/// isn't in it: their words fall outside every voice span, and diarization
/// would hand them to the nearest remote voice. This gives those words a
/// speaker of their own ("local"), so a transcript that isn't refined by
/// speaker naming afterwards still keeps them apart from everyone else.
enum LocalSpeech {
    /// A word counts as covered by a remote voice when at least this share
    /// of it lies inside that voice's spans.
    static let minimumCoverage = 0.3

    static func separate(_ result: TranscriptResult, spans: [DiarizedSpan]) -> TranscriptResult {
        let localID = (spans.map(\.speakerID).max() ?? -1) + 1
        var changed = false
        var localSeconds: TimeInterval = 0
        var segments: [TranscriptSegment] = []
        for segment in result.segments {
            guard let words = segment.words, !words.isEmpty else {
                segments.append(segment)
                continue
            }
            let relabelled = words.map { word -> TranscriptWord in
                guard !isCovered(word, by: spans) else { return word }
                return TranscriptWord(
                    word: word.word, startTime: word.startTime, endTime: word.endTime,
                    probability: word.probability, speakerID: localID
                )
            }
            guard relabelled.contains(where: { $0.speakerID == localID }) else {
                segments.append(segment)
                continue
            }
            changed = true
            for run in runs(relabelled) {
                let piece = Self.segment(run, from: segment)
                if piece.speakerID == localID { localSeconds += piece.endTime - piece.startTime }
                segments.append(piece)
            }
        }
        guard changed else { return result }
        var durations = result.speakerSpeechDurations
        durations[localID] = localSeconds
        var separated = TranscriptResult(
            id: result.id, createdAt: result.createdAt,
            transcriptionMethodId: result.transcriptionMethodId, language: result.language,
            speakerCount: max(result.speakerCount, localID + 1), segments: segments,
            embeddingSets: result.embeddingSets, speakerSpeechDurations: durations,
            processingDuration: result.processingDuration
        )
        separated.speakerSpans = result.speakerSpans
        return separated
    }

    static func isCovered(_ word: TranscriptWord, by spans: [DiarizedSpan]) -> Bool {
        let length = word.endTime - word.startTime
        if length <= 0.01 {
            return spans.contains { $0.start <= word.startTime && $0.end >= word.startTime }
        }
        let inside = spans.reduce(0.0) { total, span in
            total + max(0, min(span.end, word.endTime) - max(span.start, word.startTime))
        }
        return inside / length >= minimumCoverage
    }

    /// Consecutive words with the same speaker.
    static func runs(_ words: [TranscriptWord]) -> [[TranscriptWord]] {
        var result: [[TranscriptWord]] = []
        for word in words {
            if let last = result.last?.last, last.speakerID == word.speakerID {
                result[result.count - 1].append(word)
            } else {
                result.append([word])
            }
        }
        return result
    }

    static func segment(_ words: [TranscriptWord], from original: TranscriptSegment) -> TranscriptSegment {
        let speakerID = words.first?.speakerID
        let text = words.map(\.word).joined().trimmingCharacters(in: .whitespaces)
        return TranscriptSegment(
            speakerID: speakerID,
            speakerLabel: speakerID.map { "Speaker \($0)" } ?? original.speakerLabel,
            startTime: words.first?.startTime ?? original.startTime,
            endTime: words.last?.endTime ?? original.endTime,
            text: text,
            confidence: words.reduce(Float(0)) { $0 + $1.probability } / Float(max(words.count, 1)),
            noSpeechProbability: original.noSpeechProbability,
            words: words
        )
    }
}
