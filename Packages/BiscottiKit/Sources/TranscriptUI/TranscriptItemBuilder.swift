import DataStore
import Formatting
import Foundation
import LiveTranscriptModel

/// Builds the bubble list's items from a saved transcript or from live rows.
public enum TranscriptItemBuilder {
    /// The name and run label of the current user's bubbles.
    public static let youName = "You"
    /// The run label of the system track in a draft.
    public static let othersName = "Others"
    /// A stretch whose audio may have held sound for less time than this
    /// shows no marker: the saved transcript covers it, and a marker for
    /// every short stall alarms more than it informs.
    public static let minimumGapMarker: TimeInterval = 5
    /// Gaps this close together form one stretch.
    static let gapJoinTolerance: TimeInterval = 0.05

    // MARK: - Saved transcripts

    /// One bubble per non-blank segment.
    ///
    /// - A segment whose speaker is assigned to a person in
    ///   `currentUserPersonIDs` sits on the trailing side, named "You".
    /// - Everyone else sits on the leading side, named by `names`, then by
    ///   `speakerLabel`, and colored by `colorKeys`, then `speaker-<id>`.
    /// - A run label appears whenever the shown speaker (name and color)
    ///   differs from the previous bubble's.
    public static func saved(
        segments: [SegmentData],
        names: [Int: String],
        colorKeys: [Int: String],
        speakerPersons: [Int: UUID],
        currentUserPersonIDs: Set<UUID>
    ) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        items.reserveCapacity(segments.count)
        var previousSpeaker: (name: String, colorKey: String)?

        for segment in segments {
            let text = String(segment.text.drop(while: \.isWhitespace))
            guard !text.allSatisfy(\.isWhitespace) else { continue }

            let isCurrentUser = segment.speakerID
                .flatMap { speakerPersons[$0] }
                .map(currentUserPersonIDs.contains) ?? false
            let name = isCurrentUser
                ? youName
                : TranscriptTextFormatting.displayName(for: segment, names: names)
            let colorKey = isCurrentUser
                ? RunLabel.youColorKey
                : TranscriptContent.colorKey(for: segment, colorKeys: colorKeys)
            let startsRun = previousSpeaker.map { $0 != (name, colorKey) } ?? true
            previousSpeaker = (name, colorKey)

            let bubble = Bubble(
                side: isCurrentUser ? .trailing : .leading,
                label: startsRun
                    ? RunLabel(name: name, colorKey: colorKey, time: segment.startTime)
                    : nil,
                startsRun: startsRun,
                startTime: segment.startTime,
                endTime: segment.endTime,
                settledText: text,
                speakerID: segment.speakerID,
                spokenName: name
            )
            items.append(TranscriptItem(id: segment.id.uuidString, kind: .bubble(bubble)))
        }
        return items
    }

    // MARK: - Live rows

    /// Live rows and gap markers in time order, after an optional start marker.
    ///
    /// - Mic rows are trailing ("You"); system and mixed rows are leading.
    /// - Mixed rows never name a speaker: no label and no spoken name.
    /// - `.youOthers` labels each run "You" or "Others"; a marker ends a run.
    /// - Rows without text are skipped; a row with a tail shows typing dots,
    ///   unless the tail is incomplete (the finish ran out of time).
    /// - Touching or overlapping gaps, of either track and either silence,
    ///   form one stretch. It shows as one marker of its full length when the
    ///   parts that may have held sound (not known to be silent) total
    ///   `minimumGapMarker` or more. Silence is judged per 250 ms chunk, so a
    ///   long stall over speech with pauses records alternating silent and
    ///   spoken gaps; judged one by one, none would reach the minimum. The
    ///   gaps themselves stay in the live transcript.
    public static func live(
        rows: [LiveRow],
        gaps: [LiveGap],
        startMarker: TimeInterval?,
        labelStyle: LiveLabelStyle
    ) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        items.reserveCapacity(rows.count + gaps.count + 1)
        if let startMarker {
            items.append(TranscriptItem(id: "start-marker", kind: .startMarker(time: startMarker)))
        }

        let markers = gapMarkers(gaps)
        let timedRows = rows.filter(\.hasText).sorted { $0.startTime < $1.startTime }
        var markerIndex = 0
        var previousTrack: LiveTrack?

        func appendMarkers(through time: TimeInterval) {
            while markerIndex < markers.count, markers[markerIndex].start <= time {
                let marker = markers[markerIndex]
                items.append(TranscriptItem(
                    id: "gap-\(Int((marker.start * 1000).rounded()))",
                    kind: .gap(startTime: marker.start, duration: marker.end - marker.start, cause: marker.cause)
                ))
                markerIndex += 1
                previousTrack = nil
            }
        }

        for row in timedRows {
            appendMarkers(through: row.startTime)
            let startsRun = row.track != previousTrack
            let label = startsRun && labelStyle == .youOthers ? runLabel(for: row.track, at: row.startTime) : nil
            previousTrack = row.track
            items.append(TranscriptItem(
                id: row.id.uuidString,
                kind: .bubble(bubble(for: row, label: label, startsRun: startsRun))
            ))
        }
        appendMarkers(through: .infinity)
        return items
    }

    private static func bubble(for row: LiveRow, label: RunLabel?, startsRun: Bool) -> Bubble {
        let settled = String(row.settledText.drop(while: \.isWhitespace))
        let tail = settled.isEmpty ? String(row.tailText.drop(while: \.isWhitespace)) : row.tailText
        return Bubble(
            side: row.track == .mic ? .trailing : .leading,
            label: label,
            startsRun: startsRun,
            startTime: row.startTime,
            endTime: row.endTime,
            settledText: settled,
            tailText: tail,
            // A tail marked incomplete will never settle: no dots.
            showsTypingDots: !row.tailText.isEmpty && !row.isIncomplete,
            spokenName: spokenName(for: row.track)
        )
    }

    private static func runLabel(for track: LiveTrack, at time: TimeInterval) -> RunLabel? {
        switch track {
        case .mic: RunLabel(name: youName, colorKey: RunLabel.youColorKey, time: time)
        case .system: RunLabel(name: othersName, colorKey: RunLabel.othersColorKey, time: time)
        case .mixed: nil
        }
    }

    private static func spokenName(for track: LiveTrack) -> String? {
        switch track {
        case .mic: youName
        case .system: othersName
        case .mixed: nil
        }
    }

    /// The stretches of touching gaps that may have held sound for
    /// `minimumGapMarker` or more, in time order, each at its full length.
    /// A stretch is a device switch only when every part of it that may have
    /// held sound is a capture gap: any recorded audio the live transcript
    /// missed is in the saved transcript, and "Not transcribed live" says so.
    private static func gapMarkers(_ gaps: [LiveGap]) -> [GapStretch] {
        var stretches: [GapStretch] = []
        for gap in gaps.sorted(by: { $0.startTime < $1.startTime }) where gap.duration > 0 {
            if let last = stretches.last, gap.startTime <= last.end + gapJoinTolerance {
                stretches[stretches.count - 1].add(gap)
            } else {
                stretches.append(GapStretch(gap))
            }
        }
        return stretches
            .filter { $0.mayHaveHeldSound >= minimumGapMarker }
    }
}

/// Touching gaps, and how much of them may have held sound: the union of the
/// gaps not known to be silent. Gaps join in start-time order.
private struct GapStretch {
    let start: TimeInterval
    var end: TimeInterval
    var mayHaveHeldSound: TimeInterval = 0
    /// A gap other than a capture gap, not known to be silent, covers audio
    /// that was recorded but missed by the live transcript.
    var missedRecordedSound = false
    private var soundEnd = -TimeInterval.infinity

    var cause: GapCause {
        missedRecordedSound ? .notTranscribedLive : .deviceSwitch
    }

    init(_ gap: LiveGap) {
        start = gap.startTime
        end = gap.startTime
        add(gap)
    }

    mutating func add(_ gap: LiveGap) {
        end = max(end, gap.endTime)
        guard !gap.isSilent else { return }
        if gap.reason != .captureGap { missedRecordedSound = true }
        let from = max(gap.startTime, soundEnd)
        mayHaveHeldSound += max(0, gap.endTime - from)
        soundEnd = max(soundEnd, gap.endTime)
    }
}
