import DataStore
import Foundation
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

// MARK: - Attributed string

@Suite("TranscriptContent.attributedString")
struct TranscriptContentAttributedStringTests {
    private func makeSegments() -> [SegmentData] {
        [
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
    }

    @Test("includes seek links when canSeek is true")
    func seekLinksPresent() {
        let segments = makeSegments()
        let attributed = TranscriptContent.attributedString(
            segments, canSeek: true
        )

        // Walk the attributed string looking for link attributes
        var foundLinks: [URL] = []
        for run in attributed.runs {
            if let link = run.link {
                foundLinks.append(link)
            }
        }

        #expect(foundLinks.count == 2)
        #expect(
            foundLinks[0] == SeekLink.url(seconds: 14)
        )
        #expect(
            foundLinks[1] == SeekLink.url(seconds: 31)
        )
    }

    @Test("omits links when canSeek is false")
    func noSeekLinks() {
        let segments = makeSegments()
        let attributed = TranscriptContent.attributedString(
            segments, canSeek: false
        )

        // Walk the attributed string — no runs should have a link
        for run in attributed.runs {
            #expect(run.link == nil, "Expected no link attributes when canSeek is false")
        }
    }

    @Test("contains speaker labels and utterance text")
    func containsTextContent() {
        let segments = makeSegments()
        let attributed = TranscriptContent.attributedString(
            segments, canSeek: false
        )
        let plain = String(attributed.characters)

        #expect(plain.contains("Speaker 0"))
        #expect(plain.contains("Speaker 1"))
        #expect(plain.contains("Hello"))
        #expect(plain.contains("Hi"))
        #expect(plain.contains("0:14"))
        #expect(plain.contains("0:31"))
    }

    @Test("empty segments returns empty attributed string")
    func emptySegments() {
        let attributed = TranscriptContent.attributedString(
            [], canSeek: true
        )
        #expect(attributed.characters.isEmpty)
    }

    @Test("includes play glyph when canSeek is true")
    func playGlyphPresent() {
        let segments = [
            SegmentData(
                id: UUID(),
                speakerLabel: "Speaker 0",
                startTime: 5,
                endTime: 10,
                text: "Hello"
            )
        ]
        let attributed = TranscriptContent.attributedString(
            segments, canSeek: true
        )
        let plain = String(attributed.characters)

        // U+25B6 (black right-pointing triangle) + U+FE0E (text presentation)
        #expect(plain.contains("\u{25B6}\u{FE0E}"))
    }

    @Test("omits play glyph when canSeek is false")
    func playGlyphAbsent() {
        let segments = [
            SegmentData(
                id: UUID(),
                speakerLabel: "Speaker 0",
                startTime: 5,
                endTime: 10,
                text: "Hello"
            )
        ]
        let attributed = TranscriptContent.attributedString(
            segments, canSeek: false
        )
        let plain = String(attributed.characters)

        #expect(!plain.contains("\u{25B6}"))
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
