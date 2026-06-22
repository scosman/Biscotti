import DataStore
import Foundation
import SwiftUI
import Testing
@testable import MeetingDetailUI

/// Tests for `TranscriptListView.Equatable` conformance.
///
/// The view conforms to `Equatable` comparing `transcriptID`, `canSeek`,
/// `speakerNames`, and `speakerColorKeys` so that SwiftUI (via
/// `.equatable()`) can skip body re-evaluation when the parent
/// re-evaluates on playback ticks (~4 Hz), while still re-rendering when a
/// speaker is renamed or merged.
@Suite("TranscriptListView -- Equatable guard")
struct TranscriptListViewTests {
    private static let sampleSegments = [
        SegmentData(
            id: UUID(),
            speakerID: 0,
            speakerLabel: "Speaker 0",
            startTime: 14,
            endTime: 25,
            text: "Hello"
        )
    ]

    /// Convenience factory: builds a `TranscriptListView` with an
    /// `EmptyView` header (tests don't need page chrome).
    @MainActor
    private static func makeView(
        transcriptID: UUID = UUID(),
        canSeek: Bool = true,
        segments: [SegmentData] = sampleSegments,
        speakerNames: [Int: String] = [:],
        speakerColorKeys: [Int: String] = [:]
    ) -> TranscriptListView<EmptyView> {
        TranscriptListView(
            transcriptID: transcriptID,
            canSeek: canSeek,
            segments: segments,
            speakerNames: speakerNames,
            speakerColorKeys: speakerColorKeys,
            onSeek: { _ in },
            header: EmptyView()
        )
    }

    // MARK: - Equatable semantics

    @Test("same transcriptID and canSeek with different closures compares equal")
    @MainActor
    func sameIDDifferentClosuresAreEqual() {
        let id = UUID()
        let view1 = Self.makeView(transcriptID: id, canSeek: true)
        let view2 = Self.makeView(transcriptID: id, canSeek: true)

        #expect(view1 == view2, """
        Views with the same transcriptID and canSeek must compare equal \
        regardless of closure identity -- this is the property that \
        prevents per-tick re-evaluation during playback.
        """)
    }

    @Test("same transcriptID with different segments compares equal")
    @MainActor
    func sameIDDifferentSegmentsAreEqual() {
        let id = UUID()
        let view1 = Self.makeView(transcriptID: id, segments: Self.sampleSegments)
        let view2 = Self.makeView(transcriptID: id, segments: [])

        #expect(view1 == view2, """
        Equality depends only on transcriptID and canSeek. The segments \
        are keyed to the version via the VM, so the same ID + canSeek \
        implies the same content.
        """)
    }

    @Test("different transcriptID compares not equal")
    @MainActor
    func differentIDsAreNotEqual() {
        let view1 = Self.makeView(transcriptID: UUID())
        let view2 = Self.makeView(transcriptID: UUID())

        #expect(view1 != view2, """
        Views with different transcriptIDs must compare not-equal so \
        SwiftUI re-evaluates the body when the transcript version changes.
        """)
    }

    @Test("same transcriptID but different canSeek compares not equal")
    @MainActor
    func differentCanSeekAreNotEqual() {
        let id = UUID()
        let view1 = Self.makeView(transcriptID: id, canSeek: true)
        let view2 = Self.makeView(transcriptID: id, canSeek: false)

        #expect(view1 != view2, """
        A canSeek flip changes whether timestamps are tappable, \
        so it must trigger a body re-evaluation.
        """)
    }

    @Test("different speakerNames compares not equal")
    @MainActor
    func differentSpeakerNamesAreNotEqual() {
        let id = UUID()
        let view1 = Self.makeView(transcriptID: id, speakerNames: [:])
        let view2 = Self.makeView(
            transcriptID: id, speakerNames: [0: "Daniel"]
        )

        #expect(view1 != view2, """
        Assigning a speaker name changes the rendered label, so the view \
        must compare not-equal to trigger a re-render.
        """)
    }

    @Test("different speakerColorKeys compares not equal")
    @MainActor
    func differentSpeakerColorKeysAreNotEqual() {
        let id = UUID()
        let view1 = Self.makeView(transcriptID: id, speakerColorKeys: [:])
        let view2 = Self.makeView(
            transcriptID: id, speakerColorKeys: [0: "person-A"]
        )

        #expect(view1 != view2, """
        Merging speakers onto one person changes the shared color, so the \
        view must compare not-equal to trigger a re-render.
        """)
    }

    @Test("same speakerNames and colorKeys compares equal")
    @MainActor
    func sameSpeakerStateIsEqual() {
        let id = UUID()
        let view1 = Self.makeView(
            transcriptID: id,
            speakerNames: [0: "Daniel"],
            speakerColorKeys: [0: "person-A"]
        )
        let view2 = Self.makeView(
            transcriptID: id,
            speakerNames: [0: "Daniel"],
            speakerColorKeys: [0: "person-A"]
        )

        #expect(view1 == view2, """
        Identical speaker state with different closures must compare equal \
        so playback ticks don't force a re-render.
        """)
    }
}
