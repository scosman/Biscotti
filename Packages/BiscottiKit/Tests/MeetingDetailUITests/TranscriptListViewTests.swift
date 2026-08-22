import DataStore
import Foundation
import SwiftUI
import Testing
@testable import MeetingDetailUI

/// Tests for `TranscriptSegmentRow.Equatable` conformance.
///
/// Each transcript row conforms to `Equatable`, comparing `segment`,
/// `speakerName`, `speakerColor`, and `canSeek` -- the only things a row
/// actually renders -- so that SwiftUI (via `.equatable()` applied to
/// each row individually inside `TranscriptListView`'s `ForEach`) can
/// skip re-diffing a row whose content hasn't changed, e.g. on the
/// parent's ~4 Hz playback-tick re-render, while still re-rendering a
/// specific row when its resolved speaker name/color changes.
///
/// This guard is scoped to individual rows -- never to
/// `TranscriptListView`'s `header` -- because `header` carries page
/// chrome (including the Copy button's transient "Copied" feedback)
/// that must always re-render fresh. `ForEach` also stays a direct
/// child of `List`'s content builder (rather than being wrapped, as a
/// whole, in a container that itself produces multiple rows) so `List`
/// can identify and recycle each segment as its own row.
@Suite("TranscriptSegmentRow -- Equatable guard")
struct TranscriptListViewTests {
    private static let sampleSegment = SegmentData(
        id: UUID(),
        speakerID: 0,
        speakerLabel: "Speaker 0",
        startTime: 14,
        endTime: 25,
        text: "Hello"
    )

    /// Convenience factory: builds a `TranscriptSegmentRow`.
    @MainActor
    private static func makeRow(
        segment: SegmentData = sampleSegment,
        speakerName: String = "Speaker 0",
        speakerColor: Color = .blue,
        canSeek: Bool = true
    ) -> TranscriptSegmentRow {
        TranscriptSegmentRow(
            segment: segment,
            speakerName: speakerName,
            speakerColor: speakerColor,
            canSeek: canSeek,
            onSeek: { _ in },
            onSpeaker: { _ in }
        )
    }

    // MARK: - Equatable semantics

    @Test("same segment/name/color/canSeek with different closures compares equal")
    @MainActor
    func sameContentDifferentClosuresAreEqual() {
        let row1 = Self.makeRow()
        let row2 = Self.makeRow()

        #expect(row1 == row2, """
        Rows with identical segment/name/color/canSeek must compare \
        equal regardless of closure identity -- this is the property \
        that prevents per-tick re-evaluation during playback.
        """)
    }

    @Test("different segment compares not equal")
    @MainActor
    func differentSegmentIsNotEqual() {
        let row1 = Self.makeRow()
        let row2 = Self.makeRow(segment: SegmentData(
            id: UUID(),
            speakerID: 1,
            speakerLabel: "Speaker 1",
            startTime: 40,
            endTime: 45,
            text: "Different"
        ))

        #expect(row1 != row2, """
        A different segment (different id/content) must trigger a \
        body re-evaluation.
        """)
    }

    @Test("different speakerName compares not equal")
    @MainActor
    func differentSpeakerNameIsNotEqual() {
        let row1 = Self.makeRow(speakerName: "Speaker 0")
        let row2 = Self.makeRow(speakerName: "Daniel")

        #expect(row1 != row2, """
        Assigning a speaker name changes the rendered label, so the \
        row must compare not-equal to trigger a re-render.
        """)
    }

    @Test("different speakerColor compares not equal")
    @MainActor
    func differentSpeakerColorIsNotEqual() {
        let row1 = Self.makeRow(speakerColor: .blue)
        let row2 = Self.makeRow(speakerColor: .red)

        #expect(row1 != row2, """
        Merging speakers onto one person changes the shared color, so \
        the row must compare not-equal to trigger a re-render.
        """)
    }

    @Test("different canSeek compares not equal")
    @MainActor
    func differentCanSeekIsNotEqual() {
        let row1 = Self.makeRow(canSeek: true)
        let row2 = Self.makeRow(canSeek: false)

        #expect(row1 != row2, """
        A canSeek flip changes whether the timestamp is tappable, so \
        it must trigger a body re-evaluation.
        """)
    }
}
