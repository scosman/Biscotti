import LiveTranscriptModel

/// Sends a live session's updates to its owner, at most one per track every
/// `minimumInterval`. Updates that wait are merged (rows keep their latest
/// version by ID, gaps accumulate), never dropped.
actor LiveUpdateRelay {
    /// At most 4 updates per second per track (component spec).
    static let minimumInterval = Duration.milliseconds(250)

    private struct TrackState {
        var pending: LiveTrackUpdate?
        var lastSent: Duration?
        var timer: Task<Void, Never>?
    }

    private let clock: HostClock
    private let interval: Duration
    private let send: @Sendable (LiveTrackUpdate) -> Void
    private var tracks: [LiveTrack: TrackState] = [:]

    init(clock: HostClock, interval: Duration = minimumInterval, send: @escaping @Sendable (LiveTrackUpdate) -> Void) {
        self.clock = clock
        self.interval = interval
        self.send = send
    }

    func receive(_ update: LiveTrackUpdate) {
        var state = tracks[update.track, default: TrackState()]
        if state.pending == nil {
            state.pending = update
        } else {
            state.pending?.merge(update)
        }
        tracks[update.track] = state
        sendWhenDue(update.track)
    }

    /// Sends every pending update now: the session is ending.
    func flush() {
        for track in tracks.keys {
            tracks[track]?.timer?.cancel()
            tracks[track]?.timer = nil
            sendPending(track)
        }
    }

    private func sendWhenDue(_ track: LiveTrack) {
        guard let state = tracks[track], state.timer == nil else { return }
        let now = clock.elapsed()
        let due = state.lastSent.map { $0 + interval } ?? now
        guard due > now else {
            sendPending(track)
            return
        }
        let sleep = clock.sleep
        tracks[track]?.timer = Task {
            do { try await sleep(due - now) } catch { return }
            self.timerFired(track)
        }
    }

    private func timerFired(_ track: LiveTrack) {
        tracks[track]?.timer = nil
        sendPending(track)
    }

    private func sendPending(_ track: LiveTrack) {
        guard let update = tracks[track]?.pending else { return }
        tracks[track]?.pending = nil
        tracks[track]?.lastSent = clock.elapsed()
        send(update)
    }
}
