import DataStore
import Foundation
import Testing
@testable import MeetingDetailUI

// MARK: - Color stability

@Suite("TranscriptContent speaker color stability")
struct SpeakerColorStabilityTests {
    @Test("same speakerID with different labels produces same color")
    func colorStableAcrossRenames() {
        // Core invariant: color is keyed on speakerID, not the display
        // name / label. Two segments with the SAME speakerID but
        // DIFFERENT labels (pre-rename vs post-rename) must produce
        // the same color.
        let original = SegmentData(
            id: UUID(),
            speakerID: 2,
            speakerLabel: "Speaker 2",
            startTime: 0,
            endTime: 5,
            text: "test"
        )
        let renamed = SegmentData(
            id: UUID(),
            speakerID: 2,
            speakerLabel: "Daniel",
            startTime: 5,
            endTime: 10,
            text: "renamed"
        )

        let colorOriginal = TranscriptContent.speakerColor(for: original)
        let colorRenamed = TranscriptContent.speakerColor(for: renamed)
        #expect(
            colorOriginal == colorRenamed,
            "Same speakerID must produce the same color regardless of label"
        )
    }

    @Test("different speakerIDs produce different colors")
    func differentIDsDifferentColors() {
        let segA = SegmentData(
            id: UUID(),
            speakerID: 0,
            speakerLabel: "Speaker 0",
            startTime: 0,
            endTime: 5,
            text: ""
        )
        let segB = SegmentData(
            id: UUID(),
            speakerID: 1,
            speakerLabel: "Speaker 1",
            startTime: 5,
            endTime: 10,
            text: ""
        )
        let colorA = TranscriptContent.speakerColor(for: segA)
        let colorB = TranscriptContent.speakerColor(for: segB)
        #expect(
            colorA != colorB,
            "Different speakerIDs should produce different colors"
        )
    }

    @Test("segment without speakerID falls back to label-based color")
    func nilSpeakerIDFallsBackToLabel() {
        let segment = SegmentData(
            id: UUID(),
            speakerID: nil,
            speakerLabel: "Speaker 7",
            startTime: 0,
            endTime: 5,
            text: ""
        )
        let color = TranscriptContent.speakerColor(for: segment)
        let labelColor = TranscriptContent.speakerColor(for: "Speaker 7")
        #expect(color == labelColor)
    }
}
