import DataStore
import Formatting
import Foundation
import Testing

/// Lines Whisper was unsure of.
struct UnclearAudioTests {
    static func segment(_ id: Int, speaker: Int, at start: Double, _ words: [(String, Float)]) -> SegmentData {
        SegmentData(
            id: UUID(), speakerID: speaker, speakerLabel: "Speaker \(id)",
            startTime: start, endTime: start + 2,
            text: words.map(\.0).joined(),
            words: words.map { WordConfidence(text: $0.0, probability: $0.1) }
        )
    }

    static let clear = segment(1, speaker: 1, at: 0, [(" Can", 0.95), (" you", 0.97), (" hear", 0.9), (" me?", 0.93)])
    /// Nora's connection dropping: Whisper drifts into German.
    static let garbled = segment(2, speaker: 2, at: 5, [
        (" Security", 0.8), (" Awarenis", 0.2), (" Training,", 0.7), (" we", 0.3),
        (" haben", 0.05), (" ja", 0.1), (" schon", 0.2)
    ])
    static let loneOkay = segment(3, speaker: 3, at: 9, [(" Okay.", 0.34)])

    @Test func flagsGarbledLinesButNotClearOnesOrALoneWord() {
        #expect(!Self.clear.isUnclear)
        #expect(Self.garbled.isUnclear)
        #expect(Self.garbled.uncertainWordCount == 5)
        #expect(!Self.loneOkay.isUnclear)
    }

    @Test func exportsMarkTheHeaderButCopyTextStaysPlain() {
        let names = [1: "Brooks, Daniel", 2: "Nora Hale"]
        let segments = [Self.clear, Self.garbled]
        let marked = TranscriptTextFormatting.render(segments, names: names, markUnclear: true)
        #expect(marked.contains("[0:05] Nora Hale \u{00B7} unclear audio\n"))
        #expect(marked.contains("[0:00] Brooks, Daniel\n"))
        let plain = TranscriptTextFormatting.render(segments, names: names)
        #expect(!plain.contains("unclear audio"))
    }

    @Test func summaryCountsUnclearPlacesPerPerson() {
        let names = [2: "Nora Hale"]
        let another = Self.segment(2, speaker: 2, at: 20, [(" e", 0.1), (" não", 0.05), (" é", 0.1)])
        let summary = TranscriptTextFormatting.unclearSummary([Self.clear, Self.garbled, another], names: names)
        #expect(summary == "Unclear audio in 2 places (Nora Hale 2). Those lines are marked \u{201C}unclear audio\u{201D} below.")
        #expect(TranscriptTextFormatting.unclearSummary([Self.clear], names: names) == nil)
    }
}
