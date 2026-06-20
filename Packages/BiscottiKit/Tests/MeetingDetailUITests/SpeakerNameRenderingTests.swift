import DataStore
import Foundation
import Testing
@testable import MeetingDetailUI

// MARK: - Name replacement in attributed string

@Suite("TranscriptContent name replacement")
struct SpeakerNameReplacementTests {
    private func makeSegments() -> [SegmentData] {
        [
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
            ),
            SegmentData(
                id: UUID(),
                speakerID: 0,
                speakerLabel: "Speaker 0",
                startTime: 50,
                endTime: 60,
                text: "How are you?"
            )
        ]
    }

    @Test("shows assigned name instead of Speaker N")
    func nameReplacement() {
        let segments = makeSegments()
        let names: [Int: String] = [0: "Daniel", 1: "Priya"]

        let attributed = TranscriptContent.attributedString(
            segments, canSeek: false, names: names
        )
        let plain = String(attributed.characters)

        #expect(plain.contains("Daniel"))
        #expect(plain.contains("Priya"))
        #expect(!plain.contains("Speaker 0"))
        #expect(!plain.contains("Speaker 1"))
    }

    @Test("keeps Speaker N for unmapped speakers")
    func unmappedKeepsLabel() {
        let segments = makeSegments()
        // Only map speaker 0, leave speaker 1 unmapped
        let names = [0: "Daniel"]

        let attributed = TranscriptContent.attributedString(
            segments, canSeek: false, names: names
        )
        let plain = String(attributed.characters)

        #expect(plain.contains("Daniel"))
        #expect(plain.contains("Speaker 1"))
        #expect(!plain.contains("Speaker 0"))
    }

    @Test("empty names map shows original labels")
    func emptyNamesMap() {
        let segments = makeSegments()

        let attributed = TranscriptContent.attributedString(
            segments, canSeek: false, names: [:]
        )
        let plain = String(attributed.characters)

        #expect(plain.contains("Speaker 0"))
        #expect(plain.contains("Speaker 1"))
    }

    @Test("no names param defaults to empty map")
    func defaultNoNames() {
        let segments = makeSegments()

        let attributed = TranscriptContent.attributedString(
            segments, canSeek: false
        )
        let plain = String(attributed.characters)

        #expect(plain.contains("Speaker 0"))
        #expect(plain.contains("Speaker 1"))
    }
}

// MARK: - Speaker links in attributed string

@Suite("TranscriptContent speaker links")
struct SpeakerLinkRenderingTests {
    @Test("speaker spans have speaker links when speakerID is non-nil")
    func speakerLinksPresent() {
        let segments = [
            SegmentData(
                id: UUID(),
                speakerID: 0,
                speakerLabel: "Speaker 0",
                startTime: 0,
                endTime: 10,
                text: "Hello"
            ),
            SegmentData(
                id: UUID(),
                speakerID: 1,
                speakerLabel: "Speaker 1",
                startTime: 15,
                endTime: 25,
                text: "Hi"
            )
        ]

        let attributed = TranscriptContent.attributedString(
            segments, canSeek: false
        )

        var speakerLinks: [URL] = []
        for run in attributed.runs {
            if let link = run.link,
               SpeakerLink.speakerID(from: link) != nil
            {
                speakerLinks.append(link)
            }
        }

        #expect(speakerLinks.count == 2)
        #expect(
            SpeakerLink.speakerID(from: speakerLinks[0]) == 0
        )
        #expect(
            SpeakerLink.speakerID(from: speakerLinks[1]) == 1
        )
    }

    @Test("segments without speakerID have no speaker link")
    func noSpeakerIDNoLink() {
        let segments = [
            SegmentData(
                id: UUID(),
                speakerID: nil,
                speakerLabel: "Unknown",
                startTime: 0,
                endTime: 10,
                text: "Hello"
            )
        ]

        let attributed = TranscriptContent.attributedString(
            segments, canSeek: false
        )

        for run in attributed.runs {
            if let link = run.link {
                #expect(
                    SpeakerLink.speakerID(from: link) == nil,
                    "Segment without speakerID should not have a speaker link"
                )
            }
        }
    }

    @Test("both speaker and seek links coexist")
    func speakerAndSeekLinksCoexist() {
        let segments = [
            SegmentData(
                id: UUID(),
                speakerID: 0,
                speakerLabel: "Speaker 0",
                startTime: 5,
                endTime: 10,
                text: "Hello"
            )
        ]

        let attributed = TranscriptContent.attributedString(
            segments, canSeek: true
        )

        var seekLinks: [URL] = []
        var speakerLinks: [URL] = []
        for run in attributed.runs {
            if let link = run.link {
                if SpeakerLink.speakerID(from: link) != nil {
                    speakerLinks.append(link)
                } else if SeekLink.seconds(from: link) != nil {
                    seekLinks.append(link)
                }
            }
        }

        #expect(speakerLinks.count == 1)
        #expect(seekLinks.count == 1)
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
