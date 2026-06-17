import Foundation
import Testing
@testable import MeetingDetailUI

/// Regression tests for `SelectableTranscriptView.Equatable` conformance.
///
/// The view conforms to `Equatable` comparing `transcriptID` and `canSeek`
/// so that SwiftUI (via `.equatable()`) can skip body re-evaluation when
/// the parent re-evaluates on playback ticks. Without this, each tick
/// creates a new view with a new closure -- closures are never `Equatable`,
/// so SwiftUI re-evaluates the body, triggering a full AppKit `NSTextView`
/// re-layout that pegs the CPU for long transcripts.
@Suite("SelectableTranscriptView -- Equatable guard")
struct SelectableTranscriptViewTests {
    private static let sampleAttributed = AttributedString("Hello, world")

    // MARK: - Equatable semantics

    @Test("same transcriptID and canSeek with different closures compares equal")
    @MainActor
    func sameIDDifferentClosuresAreEqual() {
        let id = UUID()

        let view1 = SelectableTranscriptView(
            transcriptID: id,
            canSeek: true,
            attributed: Self.sampleAttributed,
            onSeek: { _ in }
        )
        let view2 = SelectableTranscriptView(
            transcriptID: id,
            canSeek: true,
            attributed: Self.sampleAttributed,
            onSeek: { _ in }
        )

        #expect(view1 == view2, """
        Views with the same transcriptID and canSeek must compare equal \
        regardless of closure identity -- this is the property that \
        prevents per-tick NSTextView re-layout during playback.
        """)
    }

    @Test("same transcriptID with different attributed strings compares equal")
    @MainActor
    func sameIDDifferentAttributedAreEqual() {
        let id = UUID()

        let view1 = SelectableTranscriptView(
            transcriptID: id,
            canSeek: true,
            attributed: AttributedString("Version A"),
            onSeek: { _ in }
        )
        let view2 = SelectableTranscriptView(
            transcriptID: id,
            canSeek: true,
            attributed: AttributedString("Version B"),
            onSeek: { _ in }
        )

        #expect(view1 == view2, """
        Equality depends only on transcriptID and canSeek. The attributed \
        string is already keyed to the version via the VM's cache, so the \
        same ID + canSeek implies the same content.
        """)
    }

    @Test("different transcriptID compares not equal")
    @MainActor
    func differentIDsAreNotEqual() {
        let view1 = SelectableTranscriptView(
            transcriptID: UUID(),
            canSeek: true,
            attributed: Self.sampleAttributed,
            onSeek: { _ in }
        )
        let view2 = SelectableTranscriptView(
            transcriptID: UUID(),
            canSeek: true,
            attributed: Self.sampleAttributed,
            onSeek: { _ in }
        )

        #expect(view1 != view2, """
        Views with different transcriptIDs must compare not-equal so \
        SwiftUI re-evaluates the body when the transcript version changes.
        """)
    }

    @Test("same transcriptID but different canSeek compares not equal")
    @MainActor
    func differentCanSeekAreNotEqual() {
        let id = UUID()

        let view1 = SelectableTranscriptView(
            transcriptID: id,
            canSeek: true,
            attributed: Self.sampleAttributed,
            onSeek: { _ in }
        )
        let view2 = SelectableTranscriptView(
            transcriptID: id,
            canSeek: false,
            attributed: Self.sampleAttributed,
            onSeek: { _ in }
        )

        #expect(view1 != view2, """
        A canSeek flip changes seek-link styling in the attributed string, \
        so it must trigger a body re-evaluation to pick up the new content.
        """)
    }
}
