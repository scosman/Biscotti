import DataStore
import Foundation
import Testing
@testable import MeetingDetailUI

// MARK: - Name replacement (display-name resolution)

@Suite("TranscriptContent.displayName")
struct SpeakerNameReplacementTests {
    private func segment(speakerID: Int?, label: String) -> SegmentData {
        SegmentData(
            id: UUID(),
            speakerID: speakerID,
            speakerLabel: label,
            startTime: 0,
            endTime: 5,
            text: "x"
        )
    }

    @Test("shows assigned name instead of Speaker N")
    func nameReplacement() {
        let names: [Int: String] = [0: "Daniel", 1: "Priya"]

        #expect(
            TranscriptContent.displayName(
                for: segment(speakerID: 0, label: "Speaker 0"),
                names: names
            ) == "Daniel"
        )
        #expect(
            TranscriptContent.displayName(
                for: segment(speakerID: 1, label: "Speaker 1"),
                names: names
            ) == "Priya"
        )
    }

    @Test("keeps Speaker N for unmapped speakers")
    func unmappedKeepsLabel() {
        // Only map speaker 0; speaker 1 stays unmapped.
        let names = [0: "Daniel"]

        #expect(
            TranscriptContent.displayName(
                for: segment(speakerID: 1, label: "Speaker 1"),
                names: names
            ) == "Speaker 1"
        )
    }

    @Test("empty names map shows original label")
    func emptyNamesMap() {
        #expect(
            TranscriptContent.displayName(
                for: segment(speakerID: 0, label: "Speaker 0"),
                names: [:]
            ) == "Speaker 0"
        )
    }

    @Test("segment without speakerID shows its label")
    func nilSpeakerIDUsesLabel() {
        #expect(
            TranscriptContent.displayName(
                for: segment(speakerID: nil, label: "Unknown"),
                names: [0: "Daniel"]
            ) == "Unknown"
        )
    }
}

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

// MARK: - Plain text with names

@Suite("TranscriptContent.plainText with names")
struct PlainTextWithNamesTests {
    @Test("substitutes names in plain text")
    func nameSubstitution() {
        let segments = [
            SegmentData(
                id: UUID(),
                speakerID: 0,
                speakerLabel: "Speaker 0",
                startTime: 14,
                endTime: 25,
                text: "Hello"
            ),
            SegmentData(
                id: UUID(),
                speakerID: 1,
                speakerLabel: "Speaker 1",
                startTime: 31,
                endTime: 45,
                text: "Hi"
            )
        ]

        let result = TranscriptContent.plainText(
            segments, names: [0: "Daniel", 1: "Priya"]
        )

        #expect(result.contains("Daniel"))
        #expect(result.contains("Priya"))
        #expect(!result.contains("Speaker 0"))
        #expect(!result.contains("Speaker 1"))
    }

    @Test("unmapped speakers keep original label in plain text")
    func unmappedKeepsLabel() {
        let segments = [
            SegmentData(
                id: UUID(),
                speakerID: 0,
                speakerLabel: "Speaker 0",
                startTime: 0,
                endTime: 5,
                text: "test"
            )
        ]

        let result = TranscriptContent.plainText(segments, names: [:])
        #expect(result.contains("Speaker 0"))
    }
}
