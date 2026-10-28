import Foundation
import LiveTranscriptModel

/// The next thing a track needs. Decodes wait for the session's one decode
/// slot; the rest is immediate.
enum TrackWork: Equatable {
    /// A later run waits behind the window: finish the window, with one
    /// final decode first when it holds audio worth decoding.
    case finishWindow(decode: Bool)
    /// The tail stayed unconfirmed through 2 s of silence: commit it as it is.
    case commitTail
    /// New audio is silent and nothing is pending: resolve it without decoding.
    case skipSilence
    case decode

    var needsDecode: Bool {
        self == .decode || self == .finishWindow(decode: true)
    }
}

/// One track of a Whisper live session: its audio, its reducer and its schedule.
struct TrackState {
    struct Watermarks: Equatable {
        var transcribedThrough: TimeInterval
        var settledThrough: TimeInterval
    }

    static let minimumNewAudio: TimeInterval = 0.5
    static let confirmAfterSilence: TimeInterval = 1
    static let commitAfterSilence: TimeInterval = 2

    var audio: TrackAudio
    var reducer: LocalAgreementReducer
    var lastDecodeAt: Duration
    /// Seconds of silent chunks at the end of the newest run.
    private(set) var trailingSilence: TimeInterval = 0
    /// True once a decode has run in the current stretch of silence. That
    /// decode covered all speech before the silence.
    private(set) var confirmedInThisSilence = false
    /// True when the last decode left out words that may still change: an
    /// unsure last word, or the words of a sound description still open at
    /// its end. Until a decode keeps them, the track waits for a confirming
    /// decode as if it had a tail, so silence does not drop them.
    var heldBackWords = false
    /// The watermarks in the last update sent, to skip updates that change nothing.
    var reportedWatermarks: Watermarks?
    /// The reducer's `latestSpeechStart` the other track's rows were last broken at.
    var handledSpeechStart: TimeInterval?

    // MARK: Catch-up

    /// True while the track works through backfill audio in catch-up decodes.
    private(set) var isCatchingUp = false
    /// Live audio arrived after the backfill: one more catch-up decode ends it.
    private(set) var reachedLiveEdge = false
    /// Audio before this time is decoded in catch-up and its words are kept.
    var catchUpThrough: TimeInterval = 0
    /// Words a catch-up decode kept, waiting to be settled in start-time
    /// order with the other track's.
    var pendingCatchUpWords: [TimedWord] = []
    /// When the session last received audio for this track.
    var lastReceivedAt: Duration = .zero

    init(track: LiveTrack, start: TimeInterval, now: Duration) {
        audio = TrackAudio(track: track, start: start)
        reducer = LocalAgreementReducer(track: track, startTime: start)
        lastDecodeAt = now
    }

    var track: LiveTrack {
        audio.track
    }

    var watermarks: Watermarks {
        Watermarks(transcribedThrough: reducer.transcribedThrough, settledThrough: reducer.settledThrough)
    }

    // MARK: - Incoming audio

    /// Why audio before a chunk is missing, when the session knows.
    struct GapBefore {
        var reason: LiveGap.Reason
        /// The session dropped the audio itself and found it silent.
        var isSilent: Bool
    }

    /// Adds a chunk. A discontinuity, or a chunk after a pause (`gapBefore`),
    /// starts a new run; the gap covers any time between the runs. Then the
    /// retention limit drops the oldest undecoded audio if decodes are behind.
    ///
    /// The audio missing before a discontinuity never reached the session, so
    /// its gap is not silent; the pump, which reports the same stretch first,
    /// knows better, and the app keeps its report.
    mutating func receive(_ chunk: LiveAudioChunk, after gapBefore: GapBefore? = nil) {
        noteBackfill(chunk.isBackfill)
        if let before = gapBefore ?? (chunk.isDiscontinuity ? GapBefore(reason: .captureGap, isSilent: false) : nil) {
            let missing = chunk.startTime - audio.end
            let gap = missing > 0
                ? LiveGap(track: track, startTime: audio.end, duration: missing, reason: before.reason, isSilent: before.isSilent)
                : nil
            audio.startRun(at: chunk.startTime, samples: chunk.samples, gap: gap)
            trailingSilence = 0
        } else {
            audio.append(chunk.samples)
        }
        if AudioLevel.isSilent(chunk.samples[...]) {
            trailingSilence += chunk.duration
        } else {
            trailingSilence = 0
            confirmedInThisSilence = false
        }
        audio.enforceRetentionLimit()
    }

    // MARK: - Catch-up

    /// What a catching-up track decodes next.
    enum CatchUpWork: Equatable {
        /// A full catch-up window from the start of the track's window.
        case window
        /// The rest of the window, keeping every word: a gap follows it
        /// (`endsRun`), or the track has received nothing for a while.
        case rest(endsRun: Bool)
        /// Live audio follows: the rest of the window, its last second left
        /// for streaming.
        case liveEdge
    }

    private mutating func noteBackfill(_ isBackfill: Bool) {
        if isBackfill {
            if !isCatchingUp {
                isCatchingUp = true
                catchUpThrough = audio.window.start
            }
            reachedLiveEdge = false
        } else if isCatchingUp {
            reachedLiveEdge = true
        }
    }

    /// The due catch-up decode. A track that has received no audio for
    /// `stallAfter` decodes what it holds too: its capture may have stopped,
    /// and waiting for a full window would hold up every track's streaming.
    ///
    /// - Parameter decodedAt: When the session's latest catch-up decode
    ///   ended. The app holds a track's audio until a decode's update
    ///   reaches it, so the quiet before then is not a stall.
    func catchUpWork(now: Duration, interval: Duration, stallAfter: Duration, decodedAt: Duration) -> CatchUpWork? {
        guard isCatchingUp, now - lastDecodeAt >= interval else { return nil }
        if audio.hasRunAfterWindow { return .rest(endsRun: true) }
        if audio.windowDuration >= LiveAudioLimits.catchUpWindow { return .window }
        if reachedLiveEdge { return .liveEdge }
        return now - max(lastReceivedAt, decodedAt) >= stallAfter ? .rest(endsRun: false) : nil
    }

    /// Ends catch-up for this track: at the live edge, or when the session finishes.
    mutating func endCatchUp() {
        isCatchingUp = false
        reachedLiveEdge = false
    }

    /// Records that a catch-up decode starts now and returns its audio.
    mutating func beginCatchUpDecode(at now: Duration, limit: Int?) -> (samples: [Float], start: TimeInterval) {
        lastDecodeAt = now
        return audio.beginDecode(limit: limit)
    }

    // MARK: - Scheduling

    func nextWork(now: Duration, interval: Duration) -> TrackWork? {
        if audio.hasRunAfterWindow {
            return .finishWindow(decode: needsFinalDecode)
        }
        let isDue = now - lastDecodeAt >= interval && newAudioDuration >= Self.minimumNewAudio
        let newAudioIsSilent = AudioLevel.isSilent(audio.undecodedWindowAudio)
        if reducer.hasTail || heldBackWords {
            // Trailing silence says nothing about audio a late pass has not
            // decoded yet; only the confirming decode makes the commit safe.
            if trailingSilence >= Self.commitAfterSilence, confirmedInThisSilence {
                return .commitTail
            }
            if isInSilence, !confirmedInThisSilence, newAudioDuration > 0 {
                return .decode
            }
            return isDue && !newAudioIsSilent ? .decode : nil
        }
        guard isDue else { return nil }
        return newAudioIsSilent ? .skipSilence : .decode
    }

    /// A final decode is worth running when the window has new audio that is
    /// speech or could still change the tail, or holds back words that a
    /// final decode keeps.
    var needsFinalDecode: Bool {
        heldBackWords || (newAudioDuration > 0 && (reducer.hasTail || !AudioLevel.isSilent(audio.undecodedWindowAudio)))
    }

    /// True after a second of silence. A decode that starts now keeps an unsure
    /// last word: the speech has ended, so no later decode would hear more of it.
    var isInSilence: Bool {
        trailingSilence >= Self.confirmAfterSilence
    }

    private var newAudioDuration: TimeInterval {
        Double(audio.undecodedWindowAudio.count) / LiveAudioChunk.sampleRate
    }

    /// Records that a decode of the whole window starts now and returns the audio to decode.
    mutating func beginDecode(at now: Duration) -> (samples: [Float], start: TimeInterval) {
        lastDecodeAt = now
        if isInSilence {
            confirmedInThisSilence = true
        }
        return audio.beginDecode()
    }
}
