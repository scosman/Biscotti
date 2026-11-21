import Foundation

// MARK: - Speech after the call ended

/// Talk in the room after you leave a call (while the recording winds
/// down) isn't part of the meeting. It's dropped only when both are true:
/// the capture shows the call ended (its timer stopped, its Leave button
/// went away) and the call audio from then on is silent.
public enum AfterCall {
    /// Words starting this long after the call's last sign are dropped.
    static let grace = 1.0
    /// Call audio quieter than this is silence.
    static let silence: Float = -50
    /// After the call, at most this share of the time may have sound.
    static let maxSoundShare = 0.15

    /// Share of frames in the range with call audio above `silence`.
    static func soundShare(_ levels: LevelTrack, from lower: Double, until upper: Double) -> Double {
        let first = max(0, Int(lower / levels.frameSeconds))
        let last = min(levels.systemDB.count, Int((upper / levels.frameSeconds).rounded(.up)))
        guard first < last else { return 0 }
        let loud = levels.systemDB[first ..< last].count { $0 > silence }
        return Double(loud) / Double(last - first)
    }

    public static func trim(_ words: [FusionWord], callEndedAt: Double?, levels: LevelTrack?) -> (words: [FusionWord], dropped: Int) {
        guard let end = callEndedAt, let levels, let last = words.last, last.end > end + grace else { return (words, 0) }
        // A call-audio track that stops before the last word can't show that
        // the room was quiet: missing frames are not silence.
        guard Double(levels.systemDB.count) * levels.frameSeconds >= last.end - levels.frameSeconds else { return (words, 0) }
        // Mostly silent, not perfectly: Teams plays a short chime as you
        // leave (about a second, 2026-11-19).
        guard soundShare(levels, from: end + grace, until: last.end) <= maxSoundShare else { return (words, 0) }
        let kept = words.filter { $0.start < end + grace }
        return (kept, words.count - kept.count)
    }
}

extension AfterCall {
    /// Voice spans cut at the call's end (plus grace), so speech heard after
    /// a trimmed call isn't reported as "[unintelligible]". Nil: no cut.
    static func clip(_ spans: [VoiceSpan], callEndedAt: Double?) -> [VoiceSpan] {
        guard let end = callEndedAt.map({ $0 + grace }) else { return spans }
        return spans.compactMap { span in
            span.start < end ? VoiceSpan(cluster: span.cluster, start: span.start, end: min(span.end, end)) : nil
        }
    }
}

extension SpeakerFuser {
    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".?!".contains(last)
    }
}
