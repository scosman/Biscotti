import Foundation
import Testing
@testable import SpeakerFusion

/// 11:29 Zoom call, no meeting-window capture. Runs only where the private
/// fixture exists (see `PrivateFixtures`).
struct EngineWord: Decodable {
    let word: String
    let startTime: Double
    let endTime: Double
    let speakerID: Int?
}

struct EngineSegment: Decodable {
    let words: [EngineWord]?
}

struct EngineSpan: Decodable {
    let speakerID: Int
    let start: Double
    let end: Double
}

struct EngineResult: Decodable {
    let segments: [EngineSegment]
    let speakerSpans: [EngineSpan]?
}

struct Meeting1129Tests {
    @Test(.enabled(if: PrivateFixtures.has("1129-transcript.json")))
    func printOpening() throws {
        let transcript = try JSONDecoder().decode(
            EngineResult.self, from: Data(contentsOf: SpeakerFusionTests.fixture("1129-transcript.json"))
        )
        let levels = try JSONDecoder().decode(
            SpeakerFusionTests.RawLevels.self, from: Data(contentsOf: SpeakerFusionTests.fixture("1129-levels.json"))
        )
        let words = transcript.segments.flatMap { $0.words ?? [] }.map {
            FusionWord(text: $0.word, start: $0.startTime, end: $0.endTime, clusterID: $0.speakerID)
        }
        let result = SpeakerFuser.fuse(
            words: words,
            levels: LevelTrack(frameSeconds: levels.frameSeconds, micDB: levels.micDB, systemDB: levels.systemDB),
            timeline: nil, userName: SpeakerFusionTests.name("user"),
            voiceSpans: (transcript.speakerSpans ?? []).map { VoiceSpan(cluster: $0.speakerID, start: $0.start, end: $0.end) }
        )
        #expect(!result.segments.isEmpty)
        // Prints real meeting speech, so only when asked (never into build logs).
        guard ProcessInfo.processInfo.environment["BISCOTTI_PRINT_MEETING"] != nil else { return }
        for segment in result.segments where segment.start < 330 || segment.text == "[unintelligible]" {
            print(String(format: "FUSED %6.1f", segment.start), segment.speaker, segment.text.prefix(110))
        }
        print("REPORT", result.report.summary)
    }
}
