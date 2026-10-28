import DataStore
import Foundation
import LiveTranscriptModel
import Testing
@testable import TranscriptUI

// MARK: - Helpers

func segment(
    _ speakerID: Int?,
    _ start: TimeInterval,
    _ text: String = "Words",
    label: String? = nil
) -> SegmentData {
    SegmentData(
        id: UUID(),
        speakerID: speakerID,
        speakerLabel: label ?? speakerID.map { "Speaker \($0)" } ?? "Unknown",
        startTime: start,
        endTime: start + 2,
        text: text
    )
}

func liveRow(
    _ track: LiveTrack,
    _ start: TimeInterval,
    settled: String = "Settled",
    tail: String = ""
) -> LiveRow {
    LiveRow(track: track, startTime: start, endTime: start + 2, settledText: settled, tailText: tail)
}

extension [TranscriptItem] {
    var bubbles: [Bubble] {
        compactMap(\.bubble)
    }
}

// MARK: - Saved transcripts

@Suite("TranscriptItemBuilder -- saved")
struct TranscriptItemBuilderSavedTests {
    private func saved(
        _ segments: [SegmentData],
        names: [Int: String] = [:],
        colorKeys: [Int: String] = [:],
        speakerPersons: [Int: UUID] = [:],
        currentUser: Set<UUID> = []
    ) -> [TranscriptItem] {
        TranscriptItemBuilder.saved(
            segments: segments,
            names: names,
            colorKeys: colorKeys,
            speakerPersons: speakerPersons,
            currentUserPersonIDs: currentUser
        )
    }

    @Test("labels appear only where the speaker changes")
    func savedLabelsOnlyAtSpeakerChange() {
        let items = saved([segment(0, 0), segment(0, 2), segment(1, 4), segment(1, 6), segment(0, 8)])

        #expect(items.bubbles.map(\.label?.name) == ["Speaker 0", nil, "Speaker 1", nil, "Speaker 0"])
        #expect(items.bubbles.map(\.startsRun) == [true, false, true, false, true])
        #expect(items.bubbles[2].label?.time == 4)
    }

    @Test("a speaker assigned to a current-user person sits on the trailing side as You")
    func savedSideIsTrailingForCurrentUserPerson() {
        let myself = UUID()
        let items = saved(
            [segment(0, 0), segment(1, 2)],
            names: [0: "Stephen", 1: "Priya"],
            colorKeys: [0: "person-\(myself)"],
            speakerPersons: [0: myself, 1: UUID()],
            currentUser: [myself]
        )

        #expect(items.bubbles.map(\.side) == [.trailing, .leading])
        #expect(items.bubbles[0].label == RunLabel(name: "You", colorKey: RunLabel.youColorKey, time: 0))
        #expect(items.bubbles[0].spokenName == "You")
        #expect(items.bubbles[1].label?.name == "Priya")
    }

    @Test("a speaker whose person is not the current user sits on the leading side")
    func savedSideIsLeadingWhenPersonUnknown() {
        let items = saved(
            [segment(0, 0), segment(1, 2)],
            names: [0: "Priya"],
            speakerPersons: [0: UUID()],
            currentUser: [UUID()]
        )

        #expect(items.bubbles.map(\.side) == [.leading, .leading])
        #expect(items.bubbles.map(\.label?.name) == ["Priya", "Speaker 1"])
    }

    @Test("a segment without a speaker ID is leading and names no clickable speaker")
    func segmentWithoutSpeakerIsLeadingWithoutAction() {
        let items = saved([segment(nil, 0, label: "Unknown Speaker")], currentUser: [UUID()])

        let bubble = items.bubbles[0]
        #expect(bubble.side == .leading)
        #expect(bubble.speakerID == nil)
        #expect(bubble.label?.name == "Unknown Speaker")
        #expect(bubble.label?.colorKey == "Unknown Speaker")
    }

    @Test("names and color keys follow assignments, then speaker labels")
    func savedNamesAndColorKeysFollowAssignments() {
        let person = UUID()
        let items = saved(
            [segment(0, 0), segment(2, 2), segment(1, 4)],
            names: [0: "Priya", 2: "Priya"],
            colorKeys: [0: "person-\(person)", 2: "person-\(person)"]
        )

        // Speakers 0 and 2 are one person: one run, one label.
        #expect(items.bubbles.map(\.label?.name) == ["Priya", nil, "Speaker 1"])
        #expect(items.bubbles[0].label?.colorKey == "person-\(person)")
        #expect(items.bubbles[2].label?.colorKey == "speaker-1")
        #expect(items.bubbles.map(\.speakerID) == [0, 2, 1])
    }

    @Test("blank segments are skipped and leading whitespace is trimmed")
    func blankSegmentsAreSkipped() {
        let first = segment(0, 0, "  Hello")
        let last = segment(1, 4, "Hi")
        let items = saved([first, segment(0, 2, "   "), last])

        #expect(items.map(\.id) == [first.id.uuidString, last.id.uuidString])
        #expect(items.bubbles.map(\.settledText) == ["Hello", "Hi"])
    }
}

// MARK: - Live rows

@Suite("TranscriptItemBuilder -- live")
struct TranscriptItemBuilderLiveTests {
    @Test("mic rows are trailing; system and mixed rows are leading")
    func liveMicRowsAreTrailingSystemLeading() {
        let items = TranscriptItemBuilder.live(
            rows: [liveRow(.system, 0), liveRow(.mic, 2), liveRow(.mixed, 4)],
            gaps: [],
            startMarker: nil,
            labelStyle: .none
        )

        #expect(items.bubbles.map(\.side) == [.leading, .trailing, .leading])
        #expect(items.bubbles.map(\.spokenName) == ["Others", "You", nil])
    }

    @Test("the drawer style has no labels")
    func liveDrawerHasNoLabels() {
        let items = TranscriptItemBuilder.live(
            rows: [liveRow(.system, 0), liveRow(.mic, 2), liveRow(.mic, 3)],
            gaps: [],
            startMarker: nil,
            labelStyle: .none
        )

        #expect(items.bubbles.allSatisfy { $0.label == nil })
        #expect(items.bubbles.map(\.startsRun) == [true, true, false])
    }

    @Test("the draft style labels runs You and Others")
    func draftLabelsYouAndOthers() {
        let items = TranscriptItemBuilder.live(
            rows: [liveRow(.system, 0), liveRow(.system, 1), liveRow(.mic, 2), liveRow(.system, 5)],
            gaps: [],
            startMarker: nil,
            labelStyle: .youOthers
        )

        #expect(items.bubbles.map(\.label) == [
            RunLabel(name: "Others", colorKey: RunLabel.othersColorKey, time: 0),
            nil,
            RunLabel(name: "You", colorKey: RunLabel.youColorKey, time: 2),
            RunLabel(name: "Others", colorKey: RunLabel.othersColorKey, time: 5)
        ])
    }

    @Test("gaps and the start marker merge with rows in time order")
    func gapsAndStartMarkerMergeInTimeOrder() {
        let early = liveRow(.mic, 10)
        let late = liveRow(.system, 30)
        let items = TranscriptItemBuilder.live(
            rows: [late, early],
            gaps: [LiveGap(track: .system, startTime: 15, duration: 12, reason: .queueOverflow)],
            startMarker: 9,
            labelStyle: .youOthers
        )

        #expect(items.map(\.id) == ["start-marker", early.id.uuidString, "gap-15000", late.id.uuidString])
        #expect(items[0].kind == .startMarker(time: 9))
        #expect(items[2].kind == .gap(startTime: 15, duration: 12, cause: .notTranscribedLive))
        // A marker ends a run, so the row after it is labeled again.
        #expect(items.bubbles[1].label?.name == "Others")
    }

    @Test("overlapping gaps from both tracks become one marker")
    func overlappingGapsMergeIntoOneMarker() {
        let items = TranscriptItemBuilder.live(
            rows: [],
            gaps: [
                LiveGap(track: .mic, startTime: 5, duration: 4, reason: .engineRestart),
                LiveGap(track: .system, startTime: 6, duration: 5, reason: .engineRestart),
                LiveGap(track: .system, startTime: 20, duration: 7, reason: .captureGap)
            ],
            startMarker: nil,
            labelStyle: .none
        )

        #expect(items.map(\.kind) == [
            .gap(startTime: 5, duration: 6, cause: .notTranscribedLive),
            .gap(startTime: 20, duration: 7, cause: .deviceSwitch)
        ])
    }

    @Test("a gap known to be silent shows no marker")
    func silentGapShowsNoMarker() {
        let items = TranscriptItemBuilder.live(
            rows: [liveRow(.mic, 30)],
            gaps: [LiveGap(track: .mic, startTime: 0, duration: 25, reason: .queueOverflow, isSilent: true)],
            startMarker: nil,
            labelStyle: .youOthers
        )

        #expect(items.count == 1)
        #expect(items.first?.bubble != nil)
    }

    @Test("a gap shorter than 5 s shows no marker; one of 5 s does")
    func gapUnderFiveSecondsShowsNoMarker() {
        let items = TranscriptItemBuilder.live(
            rows: [],
            gaps: [
                LiveGap(track: .mic, startTime: 0, duration: 4.9, reason: .captureGap),
                LiveGap(track: .mic, startTime: 10, duration: 5, reason: .engineRestart)
            ],
            startMarker: nil,
            labelStyle: .none
        )

        #expect(items.map(\.kind) == [.gap(startTime: 10, duration: 5, cause: .notTranscribedLive)])
    }

    @Test("touching gaps form one stretch, shown at its full length when 5 s of it may have held sound")
    func stretchShowsWhenItsPossibleSoundReachesFiveSeconds() {
        let items = TranscriptItemBuilder.live(
            rows: [],
            gaps: [
                // 2 s + 6 s that may have held sound inside a 16 s stretch.
                LiveGap(track: .mic, startTime: 10, duration: 10, reason: .queueOverflow, isSilent: true),
                LiveGap(track: .system, startTime: 12, duration: 2, reason: .captureGap),
                LiveGap(track: .mic, startTime: 20, duration: 6, reason: .captureGap),
                // Only 2 s that may have held sound inside a 10 s stretch.
                LiveGap(track: .mic, startTime: 40, duration: 10, reason: .queueOverflow, isSilent: true),
                LiveGap(track: .system, startTime: 42, duration: 2, reason: .captureGap)
            ],
            startMarker: nil,
            labelStyle: .none
        )

        #expect(items.map(\.kind) == [.gap(startTime: 10, duration: 16, cause: .deviceSwitch)], "the silent part does not count")
    }

    @Test("a long stall over speech with pauses, recorded chunk by chunk as silent and spoken gaps, is one marker")
    func alternatingSilentAndSpokenChunksAreOneMarker() {
        // 40 s dropped 250 ms at a time; every other chunk was a pause.
        let gaps = (0 ..< 160).map { index in
            LiveGap(track: .mic, startTime: Double(index) * 0.25, duration: 0.25, reason: .queueOverflow, isSilent: index.isMultiple(of: 2))
        }
        let items = TranscriptItemBuilder.live(rows: [], gaps: gaps, startMarker: nil, labelStyle: .none)

        #expect(items.map(\.kind) == [.gap(startTime: 0, duration: 40, cause: .notTranscribedLive)])
    }

    @Test("a stretch made only of capture gaps is a device switch: AirPods out in the hardware review")
    func deviceSwitchStretchGetsItsOwnMarker() {
        let items = TranscriptItemBuilder.live(
            rows: [],
            gaps: [
                LiveGap(track: .mic, startTime: 283.08, duration: 3.37, reason: .captureGap),
                LiveGap(track: .system, startTime: 286.43, duration: 0.60, reason: .captureGap),
                LiveGap(track: .mic, startTime: 286.95, duration: 3.07, reason: .captureGap),
                LiveGap(track: .system, startTime: 290.01, duration: 0.38, reason: .captureGap)
            ],
            startMarker: nil,
            labelStyle: .none
        )

        #expect(items.count == 1)
        guard case let .gap(start, duration, cause) = items.first?.kind else {
            Issue.record("expected one gap marker")
            return
        }
        #expect(start == 283.08)
        #expect(abs(duration - 7.31) < 1e-9)
        #expect(cause == .deviceSwitch)
    }

    @Test("a stretch where the live transcript also missed recorded audio says Not transcribed live")
    func stretchMixingDeviceSwitchAndMissedAudioIsNotTranscribedLive() {
        let items = TranscriptItemBuilder.live(
            rows: [],
            gaps: [
                LiveGap(track: .mic, startTime: 10, duration: 5, reason: .captureGap),
                LiveGap(track: .system, startTime: 12, duration: 1, reason: .engineRestart)
            ],
            startMarker: nil,
            labelStyle: .none
        )

        #expect(items.map(\.kind) == [.gap(startTime: 10, duration: 5, cause: .notTranscribedLive)])
    }

    @Test("mixed rows name no speaker in any style")
    func mixedRowsNameNoSpeakerInAnyStyle() {
        for style in [LiveLabelStyle.none, .youOthers] {
            let items = TranscriptItemBuilder.live(
                rows: [liveRow(.mixed, 0), liveRow(.mixed, 3)],
                gaps: [],
                startMarker: nil,
                labelStyle: style
            )
            #expect(items.bubbles.allSatisfy { $0.label == nil && $0.spokenName == nil })
        }
    }

    @Test("item IDs stay the same while a row's tail changes")
    func itemIDsAreStableAcrossTailUpdates() {
        var row = liveRow(.mic, 0, settled: "We ship", tail: " on Mon")
        let before = TranscriptItemBuilder.live(rows: [row], gaps: [], startMarker: nil, labelStyle: .none)
        row.settledText = "We ship on Monday"
        row.tailText = " to fifty"
        let after = TranscriptItemBuilder.live(rows: [row], gaps: [], startMarker: nil, labelStyle: .none)

        #expect(before.map(\.id) == after.map(\.id))
        #expect(before.bubbles[0].showsTypingDots)
        #expect(after.bubbles[0].tailText == " to fifty")
    }

    @Test("rows without text are skipped; a row without a tail shows no dots")
    func rowsWithoutTextAreSkipped() {
        let kept = liveRow(.system, 2, settled: "Done")
        let items = TranscriptItemBuilder.live(
            rows: [liveRow(.mic, 0, settled: "", tail: ""), kept],
            gaps: [],
            startMarker: nil,
            labelStyle: .none
        )

        #expect(items.map(\.id) == [kept.id.uuidString])
        #expect(items.bubbles[0].showsTypingDots == false)
    }

    @Test("an incomplete tail keeps its text and shows no typing dots")
    func incompleteTailShowsNoTypingDots() {
        var row = liveRow(.mic, 0, settled: "We ship", tail: " on Mon")
        row.isIncomplete = true
        let items = TranscriptItemBuilder.live(rows: [row], gaps: [], startMarker: nil, labelStyle: .youOthers)

        #expect(items.bubbles[0].tailText == " on Mon")
        #expect(items.bubbles[0].showsTypingDots == false)
    }
}

// MARK: - Plain text

@Suite("LiveTranscriptText")
struct LiveTranscriptTextTests {
    @Test("one line per bubble, prefixed You or Others; mixed rows have no prefix")
    func rendersPrefixedLines() {
        let text = LiveTranscriptText.render([
            liveRow(.system, 0, settled: " Okay, so the beta"),
            liveRow(.mic, 2, settled: "Do we have", tail: " the fix"),
            liveRow(.mic, 4, settled: "", tail: ""),
            liveRow(.mixed, 6, settled: "Mixed words")
        ])

        #expect(text == "Others: Okay, so the beta\nYou: Do we have the fix\nMixed words")
    }
}
