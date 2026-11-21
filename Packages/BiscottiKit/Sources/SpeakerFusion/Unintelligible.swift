import Foundation

/// One diarization range: when a voice was heard (whether or not Whisper
/// could transcribe it).
public struct VoiceSpan: Sendable, Equatable {
    public var cluster: Int
    public var start: Double
    public var end: Double

    public init(cluster: Int, start: Double, end: Double) {
        self.cluster = cluster
        self.start = start
        self.end = end
    }
}

/// Speech that diarization heard but Whisper produced no words
/// for (a connection breaking up, a garbled headset). Each stretch becomes
/// an "[unintelligible]" line for that voice, so technicians can see that
/// someone tried to speak.
enum Unintelligible {
    static let marker = "[unintelligible]"
    /// Shorter gaps are breaths, pauses and Whisper's word timings running
    /// short of the actual sound.
    static let minimumSeconds = 1.2
    /// Mean level a stretch needs on its louder track to count as speech.
    static let speechLevel = -40.0
    /// Words cover a little either side of their timestamps.
    static let wordPadding = 0.25

    struct Gap: Equatable {
        var cluster: Int
        var start: Double
        var end: Double
        var onMic: Bool
    }

    static func isMarker(_ word: FusionWord) -> Bool {
        word.text.trimmingCharacters(in: .whitespaces) == marker
    }

    /// Without loudness there's no telling speech from noise or whose track
    /// it's on, so nothing is reported.
    /// Voice for remote sound diarization didn't attribute to anyone.
    static let unidentifiedCluster = -1

    static func find(spans: [VoiceSpan], words: [FusionWord], levels: LevelTrack?) -> [Gap] {
        guard let levels else { return [] }
        let covered = coverage(words)
        var gaps: [Gap] = []
        for span in spans where span.end - span.start >= minimumSeconds {
            for piece in subtract(covered, from: (span.start, span.end)) where piece.1 - piece.0 >= minimumSeconds {
                guard !isPauseInsideSpeech(piece, covered: covered) else { continue }
                let mic = levels.level(levels.micDB, from: piece.0, until: piece.1)
                let system = levels.level(levels.systemDB, from: piece.0, until: piece.1)
                // Remote speech: the meeting audio at speech level and clearly
                // louder than the mic. Sounds on the user's own mic (laughs,
                // coughs, typing) aren't reported; their speech is always clear.
                guard system > speechLevel, system - mic > 6 else { continue }
                gaps.append(Gap(cluster: span.cluster, start: piece.0, end: piece.1, onMic: mic > system))
            }
        }
        // Remote sound loud enough to be speech that neither Whisper nor
        // diarization picked up (a garbled connection is often both).
        let claimed = (covered + gaps.map { ($0.start, $0.end) }).sorted { $0.0 < $1.0 }
        for run in loudSystemRuns(levels) {
            for piece in subtract(claimed, from: run) where piece.1 - piece.0 >= 1.0 {
                guard !isPauseInsideSpeech(piece, covered: covered) else { continue }
                gaps.append(Gap(cluster: unidentifiedCluster, start: piece.0, end: piece.1, onMic: false))
            }
        }
        return merge(gaps)
    }

    /// Stretches where the system track is at speech level and clearly
    /// louder than the mic. Holes under 0.25 s are bridged.
    static func loudSystemRuns(_ levels: LevelTrack) -> [(Double, Double)] {
        var runs: [(Double, Double)] = []
        var start: Int?
        var lastLoud = -10
        let count = min(levels.micDB.count, levels.systemDB.count)
        // Broken-up audio is choppy; bridge holes up to half a second.
        let bridge = Int((0.5 / levels.frameSeconds).rounded())
        for frame in 0 ..< count {
            let loud = Double(levels.systemDB[frame]) > speechLevel && levels.systemDB[frame] - levels.micDB[frame] > 6
            guard loud else { continue }
            if let open = start, frame - lastLoud > bridge {
                runs.append((Double(open) * levels.frameSeconds, Double(lastLoud + 1) * levels.frameSeconds))
                start = frame
            } else if start == nil {
                start = frame
            }
            lastLoud = frame
        }
        if let open = start {
            runs.append((Double(open) * levels.frameSeconds, Double(lastLoud + 1) * levels.frameSeconds))
        }
        return runs
    }

    /// Time covered by transcribed words (padded, merged). Words whose
    /// timing was lost can't be placed, so they cover nothing.
    static func coverage(_ words: [FusionWord]) -> [(Double, Double)] {
        let ranges = words
            .filter { $0.end - $0.start >= 0.02 }
            .map { ($0.start - wordPadding, $0.end + wordPadding) }
            .sorted { $0.0 < $1.0 }
        var merged: [(Double, Double)] = []
        for range in ranges {
            if let last = merged.last, range.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, range.1)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// A short gap with transcribed words right before and after it is a
    /// pause or loose word timing inside someone's sentence, not lost speech.
    static func isPauseInsideSpeech(_ piece: (Double, Double), covered: [(Double, Double)]) -> Bool {
        guard piece.1 - piece.0 < 2.0 else { return false }
        let before = covered.contains { abs($0.1 - piece.0) < 0.3 }
        let after = covered.contains { abs($0.0 - piece.1) < 0.3 }
        return before && after
    }

    static func subtract(_ covered: [(Double, Double)], from span: (Double, Double)) -> [(Double, Double)] {
        var pieces: [(Double, Double)] = []
        var cursor = span.0
        for range in covered where range.1 > span.0 && range.0 < span.1 {
            if range.0 > cursor { pieces.append((cursor, range.0)) }
            cursor = max(cursor, range.1)
        }
        if cursor < span.1 { pieces.append((cursor, span.1)) }
        return pieces
    }

    /// Adjacent gaps of the same voice on the same track become one.
    static func merge(_ gaps: [Gap]) -> [Gap] {
        var result: [Gap] = []
        for gap in gaps.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, last.cluster == gap.cluster, last.onMic == gap.onMic, gap.start - last.end < 0.5 {
                result[result.count - 1].end = max(last.end, gap.end)
            } else {
                result.append(gap)
            }
        }
        return result
    }
}
