/// A flag raised on a meeting's analysis results.
public enum MeetingFlag: Codable, Sendable, Equatable {
    /// Both WERs exist, the smaller > 0.02, and larger/smaller > 2.
    case werRatio(appleWER: Double, whisperWER: Double)
    /// An engine dropped a stretch of >= 30s where other engines have words.
    case droppedStretch(engine: EngineID, gapStart: Double, gapEnd: Double)
    /// An engine completed but produced zero words.
    case emptyResult(engine: EngineID)
}

/// Detects flags on a set of engine transcripts for a single meeting.
public enum Flags {

    /// Check for WER ratio flag.
    public static func checkWERRatio(appleWER: Double?, whisperWER: Double?) -> MeetingFlag? {
        guard let a = appleWER, let w = whisperWER else { return nil }
        let smaller = min(a, w)
        let larger = max(a, w)
        guard smaller > 0.02, larger / smaller > 2 else { return nil }
        return .werRatio(appleWER: a, whisperWER: w)
    }

    /// Check for empty result flags.
    public static func checkEmpty(transcripts: [(EngineID, EngineTranscript?)]) -> [MeetingFlag] {
        var flags: [MeetingFlag] = []
        for (engine, transcript) in transcripts {
            if let t = transcript, t.words.isEmpty {
                flags.append(.emptyResult(engine: engine))
            }
        }
        return flags
    }

    /// Check for dropped stretches where one engine has a gap of >= 30s and the
    /// other engines have words inside that gap.
    ///
    /// - Parameters:
    ///   - transcripts: All available engine transcripts (engine id + transcript).
    ///   - audioDuration: Total audio duration in seconds.
    public static func checkDroppedStretches(
        transcripts: [(EngineID, EngineTranscript)],
        audioDuration: Double
    ) -> [MeetingFlag] {
        var flags: [MeetingFlag] = []
        let minGap = 30.0
        let minWordsInGap = 3

        for (engine, transcript) in transcripts {
            guard transcript.hasWordTimes else { continue }

            let gaps = findGaps(in: transcript, audioDuration: audioDuration, minGap: minGap)

            for gap in gaps {
                // Check if other engines have enough words in this gap.
                let others = transcripts.filter { $0.0 != engine }
                let otherHasTimedWords = others.filter { $0.1.hasWordTimes }

                if otherHasTimedWords.isEmpty { continue }

                // When one other engine has no times (reference), require only one check.
                let requiredEngines: Int
                if others.count > otherHasTimedWords.count {
                    // Some engines lack times; only require the timed ones (>= 1).
                    requiredEngines = 1
                } else {
                    requiredEngines = otherHasTimedWords.count
                }

                var enginesCovered = 0
                for (_, other) in otherHasTimedWords {
                    let wordsInGap = other.words.filter { w in
                        guard let s = w.start, let e = w.end else { return false }
                        let mid = (s + e) / 2
                        return mid >= gap.start && mid < gap.end
                    }.count
                    if wordsInGap >= minWordsInGap {
                        enginesCovered += 1
                    }
                }

                if enginesCovered >= requiredEngines {
                    flags.append(.droppedStretch(engine: engine, gapStart: gap.start,
                                                 gapEnd: gap.end))
                }
            }
        }

        return flags
    }

    /// Find gaps of at least `minGap` seconds between consecutive timed words.
    static func findGaps(in transcript: EngineTranscript, audioDuration: Double,
                         minGap: Double) -> [(start: Double, end: Double)] {
        let timed = transcript.words.compactMap { w -> (start: Double, end: Double)? in
            guard let s = w.start, let e = w.end else { return nil }
            return (s, e)
        }.sorted { $0.start < $1.start }

        var gaps: [(start: Double, end: Double)] = []

        // Gap before first word.
        if let first = timed.first, first.start >= minGap {
            gaps.append((0, first.start))
        }

        // Gaps between consecutive words.
        for i in 1..<timed.count {
            let gapStart = timed[i - 1].end
            let gapEnd = timed[i].start
            if gapEnd - gapStart >= minGap {
                gaps.append((gapStart, gapEnd))
            }
        }

        // Gap after last word.
        if let last = timed.last, audioDuration - last.end >= minGap {
            gaps.append((last.end, audioDuration))
        }

        return gaps
    }
}
