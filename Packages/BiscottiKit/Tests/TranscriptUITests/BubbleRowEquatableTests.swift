import Foundation
import LiveTranscriptModel
import Testing
@testable import TranscriptUI

/// Each row of the bubble list is wrapped in `.equatable()` and compares
/// only what it draws: its item, its find highlights and `canSeek`. The
/// closures never take part, so a parent re-render (a playback tick, a
/// "Copied" flag in the header) skips every unchanged row.
@Suite("TranscriptItemRow -- Equatable guard")
@MainActor
struct BubbleRowEquatableTests {
    private func row(
        _ item: TranscriptItem,
        highlights: BubbleHighlights = .none,
        canSeek: Bool = true
    ) -> TranscriptItemRow {
        TranscriptItemRow(
            item: item,
            highlights: highlights,
            canSeek: canSeek,
            onSeek: { _ in },
            onSpeaker: { _ in },
            onSpeakerDebug: nil
        )
    }

    @Test("rows with equal items and different closures compare equal")
    func equalItemsSkipRerender() {
        let item = TranscriptItemBuilder.live(
            rows: [liveRow(.mic, 0, settled: "Hello")],
            gaps: [],
            startMarker: nil,
            labelStyle: .none
        )[0]

        #expect(row(item) == row(item))
    }

    @Test("a tail update changes only that row")
    func tailChangeRerendersOnlyThatRow() {
        let first = liveRow(.system, 0, settled: "Okay, so")
        var second = liveRow(.mic, 3, settled: "Do we", tail: " have")
        let before = TranscriptItemBuilder.live(rows: [first, second], gaps: [], startMarker: nil, labelStyle: .none)
        second.tailText = " have the crash fix"
        let after = TranscriptItemBuilder.live(rows: [first, second], gaps: [], startMarker: nil, labelStyle: .none)

        #expect(row(before[0]) == row(after[0]))
        #expect(row(before[1]) != row(after[1]))
    }

    @Test("a highlight or canSeek change re-renders the row")
    func highlightOrCanSeekChangeRerenders() {
        let item = TranscriptItemBuilder.live(
            rows: [liveRow(.mic, 0, settled: "Hello")],
            gaps: [],
            startMarker: nil,
            labelStyle: .none
        )[0]
        let text = item.bubble?.fullText ?? ""
        let highlight = BubbleHighlights(ranges: [text.startIndex ..< text.endIndex], currentIndex: 0)

        #expect(row(item) != row(item, highlights: highlight))
        #expect(row(item) != row(item, canSeek: false))
    }

    @Test("a gap marker says the stretch was not transcribed live, and its tooltip that nothing is lost")
    func gapMarkerCopy() {
        #expect(TranscriptItemRow.gapText(12, cause: .notTranscribedLive) == "Not transcribed live \u{00B7} 0:12")
        #expect(TranscriptItemRow.gapText(64.2, cause: .notTranscribedLive) == "Not transcribed live \u{00B7} 1:05")
        #expect(TranscriptItemRow.gapHelp(.notTranscribedLive) == "Recording continued. The saved transcript includes this part.")
    }

    @Test("a device-switch marker says audio paused, and its tooltip that nothing was recorded")
    func deviceSwitchMarkerCopy() {
        #expect(TranscriptItemRow.gapText(7.31, cause: .deviceSwitch) == "Audio paused while switching devices \u{00B7} 0:08")
        #expect(TranscriptItemRow.gapHelp(.deviceSwitch) == "Your microphone or speakers were switching; nothing was recorded here.")
    }
}
