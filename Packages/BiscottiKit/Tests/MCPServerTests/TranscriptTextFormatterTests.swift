import DataStore
import Foundation
import Testing
@testable import MCPServer

/// The transcript text format of functional spec §5.3: turn collapsing,
/// name resolution, timestamps.
@Suite("TranscriptTextFormatter")
struct TranscriptTextFormatterTests {
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

    @Test("collapses consecutive same-speaker segments into one turn")
    func collapsesSameSpeaker() {
        let text = TranscriptTextFormatter.text(
            segments: [
                segment("Hello", speaker: 0, label: "Speaker 0", start: 4),
                segment("more words", speaker: 0, label: "Speaker 0", start: 8),
                segment("Sure", speaker: 1, label: "Speaker 1", start: 31)
            ],
            names: [:]
        )
        #expect(text == "[00:04] Speaker 0\nHello more words\n\n[00:31] Speaker 1\nSure")
    }

    @Test("mapped names win; unmapped speakers keep their label")
    func nameResolution() {
        let text = TranscriptTextFormatter.text(
            segments: [
                segment("Hello", speaker: 0, label: "Speaker 0", start: 0),
                segment("Hi", speaker: 1, label: "Speaker 1", start: 5)
            ],
            names: [0: "Ada L."]
        )
        #expect(text == "[00:00] Ada L.\nHello\n\n[00:05] Speaker 1\nHi")
    }

    @Test("nil-speaker segments always start their own turn")
    func nilSpeakerTurns() {
        let text = TranscriptTextFormatter.text(
            segments: [
                segment("One", speaker: nil, label: "Unknown", start: 0),
                segment("Two", speaker: nil, label: "Unknown", start: 5),
                segment("Three", speaker: 0, label: "Speaker 0", start: 10)
            ],
            names: [:]
        )
        #expect(text == "[00:00] Unknown\nOne\n\n[00:05] Unknown\nTwo\n\n[00:10] Speaker 0\nThree")
    }

    @Test("timestamp switches to HH:MM:SS at 3600 seconds")
    func timestampBoundary() {
        let text = TranscriptTextFormatter.text(
            segments: [
                segment("Before the hour", speaker: 0, label: "S", start: 3599.9),
                segment("At the hour", speaker: 1, label: "S", start: 3600)
            ],
            names: [:]
        )
        #expect(text == "[59:59] S\nBefore the hour\n\n[01:00:00] S\nAt the hour")
    }

    @Test("empty and whitespace-only segments render no text")
    func emptyInput() {
        #expect(TranscriptTextFormatter.text(segments: [], names: [:]) == "")
        let whitespaceOnly = TranscriptTextFormatter.text(
            segments: [
                segment("  \n ", speaker: 0, label: "Speaker 0", start: 0),
                segment("", speaker: 0, label: "Speaker 0", start: 5)
            ],
            names: [:]
        )
        #expect(whitespaceOnly == "")
    }

    @Test("timestamp formats")
    func timestampFormats() {
        #expect(TranscriptTextFormatter.timestamp(0) == "00:00")
        #expect(TranscriptTextFormatter.timestamp(4.2) == "00:04")
        #expect(TranscriptTextFormatter.timestamp(604) == "10:04")
        #expect(TranscriptTextFormatter.timestamp(3600) == "01:00:00")
        #expect(TranscriptTextFormatter.timestamp(3661.9) == "01:01:01")
        #expect(TranscriptTextFormatter.timestamp(43202) == "12:00:02")
    }
}
