import Foundation
import Testing
@testable import Transcription

@Suite("SpeakerDurations")
struct SpeakerDurationsTests {
    @Test("Sums durations per speaker")
    func sumsPerSpeaker() {
        let spans = [
            DiarizedSpan(speakerID: 0, start: 0, end: 10),
            DiarizedSpan(speakerID: 1, start: 5, end: 15),
            DiarizedSpan(speakerID: 0, start: 20, end: 25)
        ]

        let durations = SpeakerDurations.compute(spans)

        #expect(durations[0] == 15.0) // 10 + 5
        #expect(durations[1] == 10.0)
    }

    @Test("Empty input gives empty output")
    func emptyInput() {
        let durations = SpeakerDurations.compute([])
        #expect(durations.isEmpty)
    }

    @Test("Negative duration is clamped to zero")
    func negativeDurationClamped() {
        let spans = [
            DiarizedSpan(speakerID: 0, start: 10, end: 5)
        ]

        let durations = SpeakerDurations.compute(spans)
        #expect(durations[0] == 0)
    }

    @Test("Single span gives its duration")
    func singleSpan() throws {
        let spans = [
            DiarizedSpan(speakerID: 2, start: 100, end: 130.5)
        ]

        let durations = SpeakerDurations.compute(spans)
        let value = try #require(durations[2])
        #expect(value == 30.5)
    }

    @Test("DiarizedSpan is Codable")
    func spanCodable() throws {
        let span = DiarizedSpan(speakerID: 1, start: 2.5, end: 7.3)
        let data = try JSONEncoder().encode(span)
        let decoded = try JSONDecoder().decode(DiarizedSpan.self, from: data)

        #expect(decoded.speakerID == 1)
        #expect(decoded.start == 2.5)
        #expect(decoded.end == 7.3)
    }
}
