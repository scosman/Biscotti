import DataStore
import Formatting
import Foundation
import Testing

// MARK: - Display name

@Suite("TranscriptTextFormatting -- displayName")
struct TranscriptTextDisplayNameTests {
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
            TranscriptTextFormatting.displayName(
                for: segment(speakerID: 0, label: "Speaker 0"),
                names: names
            ) == "Daniel"
        )
        #expect(
            TranscriptTextFormatting.displayName(
                for: segment(speakerID: 1, label: "Speaker 1"),
                names: names
            ) == "Priya"
        )
    }

    @Test("keeps the label for unmapped speakers")
    func unmappedKeepsLabel() {
        #expect(
            TranscriptTextFormatting.displayName(
                for: segment(speakerID: 1, label: "Speaker 1"),
                names: [0: "Daniel"]
            ) == "Speaker 1"
        )
    }

    @Test("segment without speakerID shows its label")
    func nilSpeakerIDUsesLabel() {
        #expect(
            TranscriptTextFormatting.displayName(
                for: segment(speakerID: nil, label: "Unknown"),
                names: [0: "Daniel"]
            ) == "Unknown"
        )
    }
}

// MARK: - Render

@Suite("TranscriptTextFormatting -- render")
struct TranscriptTextRenderTests {
    private func segment(
        _ text: String, speaker: Int?, label: String, start: TimeInterval
    ) -> SegmentData {
        SegmentData(
            id: UUID(),
            speakerID: speaker,
            speakerLabel: label,
            startTime: start,
            endTime: start + 5,
            text: text
        )
    }

    @Test("renders one header line per turn with a blank line between")
    func multiTurn() {
        let text = TranscriptTextFormatting.render([
            segment("Hello", speaker: 0, label: "Speaker 0", start: 14),
            segment("Hi", speaker: 1, label: "Speaker 1", start: 31)
        ])
        #expect(text == "[0:14] Speaker 0\nHello\n\n[0:31] Speaker 1\nHi")
    }

    @Test("collapses consecutive same-speaker segments into one turn")
    func collapsesSameSpeaker() {
        let text = TranscriptTextFormatting.render([
            segment("Hello", speaker: 0, label: "Speaker 0", start: 4),
            segment("more words", speaker: 0, label: "Speaker 0", start: 8),
            segment("Sure", speaker: 1, label: "Speaker 1", start: 31)
        ])
        #expect(text == "[0:04] Speaker 0\nHello more words\n\n[0:31] Speaker 1\nSure")
    }

    @Test("nil-speaker segments never collapse")
    func nilSpeakerNeverCollapses() {
        let text = TranscriptTextFormatting.render([
            segment("One", speaker: nil, label: "Unknown", start: 0),
            segment("Two", speaker: nil, label: "Unknown", start: 5),
            segment("Three", speaker: 0, label: "Speaker 0", start: 10)
        ])
        #expect(text == "[0:00] Unknown\nOne\n\n[0:05] Unknown\nTwo\n\n[0:10] Speaker 0\nThree")
    }

    @Test("mapped names win; unmapped speakers keep their label")
    func nameResolution() {
        let text = TranscriptTextFormatting.render(
            [
                segment("Hello", speaker: 0, label: "Speaker 0", start: 0),
                segment("Hi", speaker: 1, label: "Speaker 1", start: 5)
            ],
            names: [0: "Ada L."]
        )
        #expect(text == "[0:00] Ada L.\nHello\n\n[0:05] Speaker 1\nHi")
    }

    @Test("timestamps switch to H:MM:SS at one hour")
    func hourPlusTimestamps() {
        let text = TranscriptTextFormatting.render([
            segment("Before the hour", speaker: 0, label: "S", start: 3599.9),
            segment("At the hour", speaker: 1, label: "S", start: 3600),
            segment("Late", speaker: 2, label: "S", start: 4322)
        ])
        #expect(text == "[59:59] S\nBefore the hour\n\n[1:00:00] S\nAt the hour\n\n[1:12:02] S\nLate")
    }

    @Test("drops blank segments and renders empty input as empty string")
    func blankSegments() {
        #expect(TranscriptTextFormatting.render([]) == "")
        let whitespaceOnly = TranscriptTextFormatting.render([
            segment("  \n ", speaker: 0, label: "Speaker 0", start: 0),
            segment("", speaker: 0, label: "Speaker 0", start: 5)
        ])
        #expect(whitespaceOnly == "")
    }
}

// MARK: - Parse

@Suite("TranscriptTextFormatting -- parse")
struct TranscriptTextParseTests {
    @Test("plain text with no headers imports as Unknown Speaker at 0")
    func plainText() {
        let drafts = TranscriptTextFormatting.parse("Just talking\nStill talking")
        #expect(drafts.count == 2)
        #expect(
            drafts.map(\.speakerLabel)
                == ["Unknown Speaker", "Unknown Speaker"]
        )
        #expect(drafts.map(\.startTime) == [0, 0])
        #expect(drafts.map(\.speakerID) == [0, 0])
    }

    @Test("parses our own rendered format")
    func ownFormat() {
        let drafts = TranscriptTextFormatting.parse(
            "[0:23] Steve\nLet's get started.\n\n[0:31] Priya\nI pushed the fix this morning."
        )
        #expect(drafts.count == 2)
        #expect(drafts[0].speakerLabel == "Steve")
        #expect(drafts[0].startTime == 23)
        #expect(drafts[0].text == "Let's get started.")
        #expect(drafts[1].speakerLabel == "Priya")
        #expect(drafts[1].startTime == 31)
        #expect(drafts[1].text == "I pushed the fix this morning.")
    }

    @Test("splits 'Name: inline text' headers into speaker plus content")
    func inlineTextAfterColon() {
        let drafts = TranscriptTextFormatting.parse("[0:23] Steve: hello there")
        #expect(drafts.count == 1)
        #expect(drafts[0].speakerLabel == "Steve")
        #expect(drafts[0].startTime == 23)
        #expect(drafts[0].text == "hello there")
    }

    @Test("parses H:MM:SS and HH:MM:SS headers")
    func hourPlusHeaders() {
        let drafts = TranscriptTextFormatting.parse(
            "[1:02:03] A\none\n\n[12:00:02] B\ntwo\n\n[2:05] C\nthree"
        )
        #expect(drafts.map(\.startTime) == [3723, 43202, 125])
        #expect(drafts.map(\.speakerLabel) == ["A", "B", "C"])
    }

    @Test("one line makes one segment; nothing is merged")
    func oneSegmentPerLine() {
        let drafts = TranscriptTextFormatting.parse("[0:10] A\nfirst\nsecond\nthird")
        #expect(drafts.count == 3)
        #expect(drafts.map(\.text) == ["first", "second", "third"])
        #expect(drafts.map(\.speakerID) == [0, 0, 0])
    }

    @Test("splits on CRLF, LF, and CR; drops blank lines")
    func lineSplits() {
        let drafts = TranscriptTextFormatting.parse("a\r\nb\rc\n\nd\r\n\r\n")
        #expect(drafts.map(\.text) == ["a", "b", "c", "d"])
    }

    @Test("speaker IDs are sequential in first-appearance order")
    func sequentialSpeakerIDs() {
        let drafts = TranscriptTextFormatting.parse(
            "[0:00] B\none\n\n[0:10] A\ntwo\n\n[0:20] B\nthree"
        )
        #expect(drafts.map(\.speakerLabel) == ["B", "A", "B"])
        #expect(drafts.map(\.speakerID) == [0, 1, 0])
    }

    @Test("header with no name means Unknown Speaker")
    func namelessHeader() {
        let drafts = TranscriptTextFormatting.parse("[0:42]\nsome words")
        #expect(drafts.count == 1)
        #expect(drafts[0].speakerLabel == "Unknown Speaker")
        #expect(drafts[0].startTime == 42)
    }

    @Test("text before the first header is Unknown Speaker at 0")
    func textBeforeFirstHeader() {
        let drafts = TranscriptTextFormatting.parse("preamble\n[0:05] A\nanswer")
        #expect(drafts.count == 2)
        #expect(drafts[0].speakerLabel == "Unknown Speaker")
        #expect(drafts[0].startTime == 0)
        #expect(drafts[1].speakerLabel == "A")
        #expect(drafts[1].startTime == 5)
    }

    @Test("bracketed non-timestamps stay content lines")
    func bracketedNonTimestamps() {
        let drafts = TranscriptTextFormatting.parse("[see attached]\n[1:2] too short")
        #expect(drafts.map(\.text) == ["[see attached]", "[1:2] too short"])
        #expect(drafts.map(\.speakerLabel) == ["Unknown Speaker", "Unknown Speaker"])
    }

    @Test("empty input yields no segments")
    func emptyInput() {
        #expect(TranscriptTextFormatting.parse("").isEmpty)
        #expect(TranscriptTextFormatting.parse(" \n \r\n ").isEmpty)
    }
}

// MARK: - Round-trip

@Suite("TranscriptTextFormatting -- round-trip")
struct TranscriptTextRoundTripTests {
    @Test("render then parse preserves speakers, times, and words")
    func roundTrip() {
        let segments = [
            SegmentData(
                id: UUID(), speakerID: 0, speakerLabel: "Speaker 0",
                startTime: 23, endTime: 30, text: "Let's get started."
            ),
            SegmentData(
                id: UUID(), speakerID: 0, speakerLabel: "Speaker 0",
                startTime: 31, endTime: 40, text: "Second fragment."
            ),
            SegmentData(
                id: UUID(), speakerID: 1, speakerLabel: "Speaker 1",
                startTime: 3723, endTime: 3740, text: "Late in the meeting."
            )
        ]

        let drafts = TranscriptTextFormatting.parse(TranscriptTextFormatting.render(segments))

        // Same-speaker fragments collapse into one turn on render, so the
        // round-trip preserves speakers, timestamps, and words — not
        // fragment boundaries (architecture §3.3).
        #expect(drafts.count == 2)
        #expect(drafts[0].speakerLabel == "Speaker 0")
        #expect(drafts[0].startTime == 23)
        #expect(drafts[0].text == "Let's get started. Second fragment.")
        #expect(drafts[1].speakerLabel == "Speaker 1")
        #expect(drafts[1].startTime == 3723)
        #expect(drafts[1].text == "Late in the meeting.")
    }
}
