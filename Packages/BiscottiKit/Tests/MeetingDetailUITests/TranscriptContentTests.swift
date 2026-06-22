import DataStore
import Foundation
import SwiftUI
import Testing
@testable import MeetingDetailUI

// MARK: - Plain text

@Suite("TranscriptContent.plainText")
struct TranscriptContentPlainTextTests {
    @Test("formats multi-turn transcript")
    func multiTurn() {
        let segments = [
            SegmentData(
                id: UUID(),
                speakerLabel: "Speaker 0",
                startTime: 14,
                endTime: 25,
                text: "Hello"
            ),
            SegmentData(
                id: UUID(),
                speakerLabel: "Speaker 1",
                startTime: 31,
                endTime: 45,
                text: "Hi"
            )
        ]

        let result = TranscriptContent.plainText(segments)

        #expect(result == "Speaker 0  0:14\nHello\n\nSpeaker 1  0:31\nHi")
    }

    @Test("formats H:MM:SS for times >= 1 hour")
    func hourFormat() {
        let segments = [
            SegmentData(
                id: UUID(),
                speakerLabel: "Speaker 0",
                startTime: 3723, // 1:02:03
                endTime: 3780,
                text: "Late in the meeting"
            )
        ]

        let result = TranscriptContent.plainText(segments)

        #expect(result == "Speaker 0  1:02:03\nLate in the meeting")
    }

    @Test("single segment has no trailing separator")
    func singleSegment() {
        let segments = [
            SegmentData(
                id: UUID(),
                speakerLabel: "Alice",
                startTime: 0,
                endTime: 5,
                text: "Solo"
            )
        ]

        let result = TranscriptContent.plainText(segments)

        #expect(result == "Alice  0:00\nSolo")
    }

    @Test("empty segments returns empty string")
    func emptySegments() {
        let result = TranscriptContent.plainText([])
        #expect(result.isEmpty)
    }
}

// MARK: - Speaker color

@Suite("TranscriptContent.speakerColor")
struct TranscriptContentSpeakerColorTests {
    @Test("same label returns same color")
    func sameLabel() {
        let color1 = TranscriptContent.speakerColor(for: "Speaker 0")
        let color2 = TranscriptContent.speakerColor(for: "Speaker 0")
        #expect(color1 == color2)
    }

    @Test("different labels return different colors (spot check)")
    func differentLabels() {
        // With distinct strings and 16 palette entries, collisions are
        // possible but highly unlikely for a small set of labels.
        let labels = ["Speaker 0", "Speaker 1", "Speaker 2", "Speaker 3"]
        let colors = Set(labels.map {
            TranscriptContent.speakerColor(for: $0).description
        })
        #expect(colors.count >= 2, "Expected at least 2 distinct colors among 4 speakers")
    }
}

// MARK: - Merged speaker color (Phase 11)

@Suite("TranscriptContent.speakerColor — merged speakers (§13.5)")
struct TranscriptContentMergedSpeakerColorTests {
    @Test("two speaker IDs assigned to same person produce identical color")
    func mergedSpeakersShareColor() {
        let personID = UUID()
        let colorKeys: [Int: String] = [
            0: "person-\(personID.uuidString)",
            2: "person-\(personID.uuidString)"
        ]

        let seg0 = SegmentData(
            id: UUID(), speakerID: 0,
            speakerLabel: "Speaker 0",
            startTime: 0, endTime: 5, text: "Hello"
        )
        let seg2 = SegmentData(
            id: UUID(), speakerID: 2,
            speakerLabel: "Speaker 2",
            startTime: 5, endTime: 10, text: "Hi"
        )

        let color0 = TranscriptContent.speakerColor(
            for: seg0, colorKeys: colorKeys
        )
        let color2 = TranscriptContent.speakerColor(
            for: seg2, colorKeys: colorKeys
        )

        #expect(color0 == color2)
    }

    @Test("unassigned speakers keep stable per-ID color")
    func unassignedSpeakersKeepStableColor() {
        // No color key overrides -- should use "speaker-<id>"
        let seg = SegmentData(
            id: UUID(), speakerID: 1,
            speakerLabel: "Speaker 1",
            startTime: 0, endTime: 5, text: "Hello"
        )

        let colorWithEmptyKeys = TranscriptContent.speakerColor(
            for: seg, colorKeys: [:]
        )
        let colorWithNoKeys = TranscriptContent.speakerColor(for: seg)

        #expect(colorWithEmptyKeys == colorWithNoKeys)
        // Also matches the label-based legacy method
        #expect(colorWithNoKeys == TranscriptContent.speakerColor(for: "speaker-1"))
    }

    @Test("speakerColor(forSpeakerID:colorKeys:) matches segment-based method")
    func forSpeakerIDMatchesSegmentMethod() {
        let personID = UUID()
        let colorKeys = [
            0: "person-\(personID.uuidString)"
        ]

        let seg = SegmentData(
            id: UUID(), speakerID: 0,
            speakerLabel: "Speaker 0",
            startTime: 0, endTime: 5, text: "Hello"
        )

        let segColor = TranscriptContent.speakerColor(
            for: seg, colorKeys: colorKeys
        )
        let idColor = TranscriptContent.speakerColor(
            forSpeakerID: 0, colorKeys: colorKeys
        )

        #expect(segColor == idColor)
    }

    @Test("forSpeakerID without override falls back to speaker-ID key")
    func forSpeakerIDFallback() {
        let color = TranscriptContent.speakerColor(
            forSpeakerID: 3, colorKeys: [:]
        )
        #expect(color == TranscriptContent.speakerColor(for: "speaker-3"))
    }
}
