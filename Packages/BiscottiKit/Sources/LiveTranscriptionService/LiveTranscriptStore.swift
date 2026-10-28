import Foundation
import LiveTranscriptModel
import os

/// One recording's live transcript: rows from every track in start-time
/// order, the gaps, and how far each track is transcribed and settled.
struct LiveTranscriptStore {
    /// A track this far behind the newest captured audio has stopped
    /// delivering: it is stalled, and neither holds back the settled time nor
    /// counts toward catching up until it delivers again.
    static let stallThreshold: TimeInterval = 3
    /// Live text this far behind the audio on an active track is catching up.
    static let catchUpThreshold: TimeInterval = 10
    /// Gaps of one track this close together are one gap.
    static let gapJoinTolerance: TimeInterval = 0.05

    private static let log = Logger(subsystem: "net.scosman.biscotti", category: "live")

    private struct TrackProgress {
        var transcribedThrough: TimeInterval
        var settledThrough: TimeInterval
        var revision: Int
    }

    let sessionID: UUID
    /// Where this recording's live transcript starts: 0, or the time live
    /// transcription was turned on mid-recording.
    let startTime: TimeInterval
    private(set) var generation = 0
    /// Updates applied so far.
    private(set) var revision = 0
    /// In start-time order across tracks.
    private(set) var rows: [LiveRow] = []
    /// In start-time order; overlapping gaps of one track are merged.
    private(set) var gaps: [LiveGap] = []
    private(set) var detectedLanguage: String?
    /// How far each track's captured audio reaches, from the pump.
    private(set) var captured: [LiveTrack: TimeInterval] = [:]
    private var rowIndex: [UUID: Int] = [:]
    private var progress: [LiveTrack: TrackProgress] = [:]
    /// Hears about settled text that changed instead of growing, after it is
    /// logged as a fault. The app only logs, because a crash would end the
    /// recording. Tests stop.
    private let onSettledTextViolation: @Sendable (String) -> Void

    init(
        sessionID: UUID,
        startTime: TimeInterval = 0,
        onSettledTextViolation: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.sessionID = sessionID
        self.startTime = startTime
        self.onSettledTextViolation = onSettledTextViolation
    }

    /// True once an update of any generation has been applied.
    var hasUpdates: Bool {
        revision > 0
    }

    /// The end of the newest captured audio on any track.
    var captureWatermark: TimeInterval {
        captured.values.max() ?? startTime
    }

    // MARK: - Changes

    /// Applies an update from the current generation. Rows replace the rows
    /// with the same ID; new rows join in time order. Returns false when the
    /// update is from another session or generation, or older than one
    /// already applied for its track.
    @discardableResult
    mutating func apply(_ update: LiveTrackUpdate) -> Bool {
        guard update.sessionID == sessionID, update.generation == generation else { return false }
        if let known = progress[update.track], update.revision < known.revision { return false }
        var needsSort = false
        for row in update.rows {
            needsSort = place(row) || needsSort
        }
        if needsSort { sortRows() }
        for gap in update.gaps {
            addGap(gap)
        }
        progress[update.track] = TrackProgress(
            transcribedThrough: update.transcribedThrough,
            settledThrough: update.settledThrough,
            revision: update.revision
        )
        detectedLanguage = update.detectedLanguage ?? detectedLanguage
        revision += 1
        return true
    }

    /// Records a stretch of a track the live transcript misses.
    ///
    /// The earlier report of a stretch wins: the session's gap for a
    /// discontinuity repeats the pump's gap for the same stretch, and only the
    /// pump knows whether the audio it dropped was silent. So a new gap adds
    /// only the time no recorded gap of its track covers, and each new
    /// stretch joins the touching gaps of the same reason and silence. A
    /// capture gap never joins another reason: the transcript shows a stretch
    /// made only of capture gaps as a device switch, with nothing recorded.
    mutating func addGap(_ gap: LiveGap) {
        guard gap.duration > 0 else { return }
        let sameTrack = gaps.filter { $0.track == gap.track }
        var pieces = [gap.startTime ..< gap.endTime]
        for covered in sameTrack {
            pieces = pieces.flatMap { Self.subtract(covered.startTime ..< covered.endTime, from: $0) }
        }
        let overlapped = pieces != [gap.startTime ..< gap.endTime]
        for piece in pieces where !overlapped || piece.upperBound - piece.lowerBound > Self.gapJoinTolerance {
            var part = gap
            part.startTime = piece.lowerBound
            part.duration = piece.upperBound - piece.lowerBound
            insertJoiningNeighbors(part)
        }
    }

    private mutating func insertJoiningNeighbors(_ gap: LiveGap) {
        var merged = gap
        var mergedEnd = gap.endTime
        gaps.removeAll { existing in
            guard existing.track == gap.track,
                  existing.reason == gap.reason,
                  existing.isSilent == gap.isSilent,
                  existing.startTime <= mergedEnd + Self.gapJoinTolerance,
                  existing.endTime >= merged.startTime - Self.gapJoinTolerance
            else { return false }
            merged.startTime = min(merged.startTime, existing.startTime)
            mergedEnd = max(mergedEnd, existing.endTime)
            return true
        }
        merged.duration = mergedEnd - merged.startTime
        let index = gaps.firstIndex { $0.startTime > merged.startTime } ?? gaps.endIndex
        gaps.insert(merged, at: index)
    }

    /// What is left of `range` outside `covered`.
    private static func subtract(_ covered: Range<TimeInterval>, from range: Range<TimeInterval>) -> [Range<TimeInterval>] {
        guard covered.overlaps(range) else { return [range] }
        var rest: [Range<TimeInterval>] = []
        if range.lowerBound < covered.lowerBound { rest.append(range.lowerBound ..< covered.lowerBound) }
        if covered.upperBound < range.upperBound { rest.append(covered.upperBound ..< range.upperBound) }
        return rest
    }

    mutating func recordCapture(_ captured: [LiveTrack: TimeInterval]) {
        self.captured.merge(captured) { max($0, $1) }
    }

    /// A restarted engine starts a new generation. The old generation's
    /// tails can no longer settle, so they are dropped and their rows closed.
    mutating func beginGeneration(_ generation: Int) {
        self.generation = generation
        for index in rows.indices where !rows[index].tailText.isEmpty {
            rows[index].tailText = ""
            rows[index].isClosed = true
        }
        progress = progress.mapValues { TrackProgress(transcribedThrough: $0.transcribedThrough, settledThrough: $0.settledThrough, revision: 0) }
    }

    /// The finish ran out of time: tails stay, marked incomplete.
    mutating func markTailsIncomplete() {
        for index in rows.indices where !rows[index].tailText.isEmpty {
            rows[index].isIncomplete = true
        }
    }

    // MARK: - Reading

    /// A track is active while its audio keeps arriving: it has captured
    /// audio no more than `stallThreshold` behind the newest on any track.
    func isActive(_ track: LiveTrack) -> Bool {
        guard let end = captured[track] else { return false }
        return captureWatermark - end <= Self.stallThreshold
    }

    var activeTracks: [LiveTrack] {
        captured.keys.filter(isActive).sorted { $0.rawValue < $1.rawValue }
    }

    /// Audio decoded at least once, extended through recorded gaps.
    func transcribedThrough(_ track: LiveTrack) -> TimeInterval {
        extendedThroughGaps(progress[track]?.transcribedThrough ?? startTime, on: track)
    }

    /// Audio resolved, extended through recorded gaps: settled text,
    /// processed silence or a gap.
    func settledThrough(_ track: LiveTrack) -> TimeInterval {
        extendedThroughGaps(progress[track]?.settledThrough ?? startTime, on: track)
    }

    /// True when an active track's live text is more than `catchUpThreshold`
    /// behind the newest captured audio.
    var isCatchingUp: Bool {
        let watermark = captureWatermark
        return activeTracks.contains { watermark - transcribedThrough($0) > Self.catchUpThreshold }
    }

    /// A frozen copy. Without the tail, tails are stripped, and a row that had
    /// one ends no later than its track's settled time, so the copy never
    /// reaches past settled text.
    func snapshot(includeTail: Bool) -> LiveTranscriptSnapshot {
        let tracks = activeTracks.isEmpty ? Array(captured.keys) : activeTracks
        let snapshotRows = includeTail ? rows : rows.map(settledPart)
        return LiveTranscriptSnapshot(
            sessionID: sessionID,
            revision: revision,
            captureWatermark: captureWatermark,
            transcribedThrough: tracks.map(transcribedThrough).min() ?? startTime,
            settledThrough: tracks.map(settledThrough).min() ?? startTime,
            rows: snapshotRows,
            gaps: gaps,
            includesTail: includeTail
        )
    }

    // MARK: - Private

    /// Puts a row in place. Returns true when the rows need sorting.
    private mutating func place(_ row: LiveRow) -> Bool {
        guard let index = rowIndex[row.id] else {
            let outOfOrder = rows.last.map { $0.startTime > row.startTime } ?? false
            rowIndex[row.id] = rows.count
            rows.append(row)
            return outOfOrder
        }
        let old = rows[index]
        guard row.settledText.hasPrefix(old.settledText) else {
            let message = "Live settled text changed instead of growing (\(old.settledText.count) to \(row.settledText.count) characters); the update for the row was rejected"
            Self.log.fault("\(message, privacy: .public)")
            onSettledTextViolation(message)
            return false
        }
        rows[index] = row
        return row.startTime != old.startTime
    }

    private mutating func sortRows() {
        rows = rows.enumerated()
            .sorted { ($0.element.startTime, $0.offset) < ($1.element.startTime, $1.offset) }
            .map(\.element)
        rowIndex = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
    }

    private func extendedThroughGaps(_ time: TimeInterval, on track: LiveTrack) -> TimeInterval {
        var through = time
        for gap in gaps where gap.track == track && gap.startTime <= through + Self.gapJoinTolerance {
            through = max(through, gap.endTime)
        }
        return through
    }

    private func settledPart(of row: LiveRow) -> LiveRow {
        guard !row.tailText.isEmpty else { return row }
        var row = row
        row.endTime = max(row.startTime, min(row.endTime, settledThrough(row.track)))
        return row
    }
}
