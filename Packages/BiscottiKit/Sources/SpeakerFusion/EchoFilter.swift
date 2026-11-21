import Foundation

// MARK: - Your own voice echoed back

/// A remote participant whose speakers feed their microphone sends your own
/// words back a moment later. Whisper hears them twice: once on your mic and
/// once in the meeting audio, where diarization gives them a voice of their
/// own ("Speaker 4: still can't hear you.").
///
/// A run of meeting-audio words not credited to a named participant is
/// treated as an echo only when the meeting's live captions can vouch for
/// it: captions were on, no one but you was captioned around that moment,
/// and the run repeats what you had just said on your mic. Without captions
/// nothing is dropped.
enum EchoFilter {
    struct Tuning {
        /// How far back to look for the words being repeated.
        var lookBack = 4.0
        /// Shortest run worth checking ("you" alone could be anything).
        var minimumWords = 3
        /// Share of the run that must repeat the user's words, in order.
        var minimumShare = 0.8
        /// A silence this long ends a run.
        var runGap = 1.0
        /// Captions must appear this close before and after a run. Captions
        /// don't record being switched off, so a wide window could span an
        /// off-then-on gap and drop real speech as an echo; keeping an echo
        /// now and then is the safer mistake.
        var coverage = 10.0
    }

    /// Indexes of words that echo the user.
    static func echoes(
        _ words: [FusionWord],
        speakers: [FusedSpeaker],
        sources: [WordSource],
        captions: [CaptionLine],
        userName: String,
        tuning: Tuning = Tuning()
    ) -> Set<Int> {
        guard !captions.isEmpty else { return [] }
        let others = captions.filter { !PersonName.same($0.name, userName) }
        var result: Set<Int> = []
        for run in remoteRuns(words, speakers: speakers, sources: sources, gap: tuning.runGap) {
            let tokens = run.map { CaptionAligner.normalize(words[$0].text) }.filter { !$0.isEmpty }
            guard tokens.count >= tuning.minimumWords, run.contains(where: { sources[$0] == .system }),
                  let first = run.first, let last = run.last else { continue }
            let start = words[first].start
            let end = words[last].end
            let tuningWindow = CaptionAligner.Tuning()
            // Captions must have been running on both sides of the run (they
            // can be turned off mid-meeting), and no one else captioned in it.
            let vouched = captionsRunning(captions, around: start ... end, within: tuning.coverage)
                && !others.contains { $0.start - tuningWindow.lead < end && $0.end + tuningWindow.tail > start }
            guard vouched else { continue }
            let recent = words.indices.filter {
                sources[$0] == .mic && words[$0].start >= start - tuning.lookBack && words[$0].start < start
            }.map { CaptionAligner.normalize(words[$0].text) }.filter { !$0.isEmpty }
            let repeated = CaptionAligner.longestCommon(tokens, recent).count
            if Double(repeated) >= Double(tokens.count) * tuning.minimumShare {
                result.formUnion(run)
            }
        }
        return result
    }

    /// Some caption (anyone's) shortly before the run and another shortly
    /// after it.
    static func captionsRunning(_ captions: [CaptionLine], around run: ClosedRange<Double>, within seconds: Double) -> Bool {
        let before = captions.contains { $0.start <= run.lowerBound && $0.end >= run.lowerBound - seconds }
        let after = captions.contains { $0.end >= run.upperBound && $0.start <= run.upperBound + seconds }
        return before && after
    }

    /// Consecutive words that weren't loudest on the user's mic and that no
    /// named participant claims. Words whose timing Whisper squeezed can't be
    /// measured (unknown source); they join the run, which still needs at
    /// least one word that was clearly in the meeting audio.
    static func remoteRuns(_ words: [FusionWord], speakers: [FusedSpeaker], sources: [WordSource], gap: Double) -> [[Int]] {
        var runs: [[Int]] = []
        for index in words.indices {
            guard sources[index] != .mic else { continue }
            if case .person = speakers[index] { continue }
            if let previous = runs.last?.last, previous == index - 1, words[index].start - words[previous].end < gap {
                runs[runs.count - 1].append(index)
            } else {
                runs.append([index])
            }
        }
        return runs
    }
}
