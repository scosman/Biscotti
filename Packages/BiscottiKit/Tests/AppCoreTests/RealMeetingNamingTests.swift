import Foundation
import SpeakerFusion
import Testing
import Transcription
@testable import AppCore

/// Runs speaker naming on real files named by environment
/// variables and prints the result. Skipped unless BISCOTTI_REAL_JSON is set.
/// BISCOTTI_REAL_JSON: transcribe-cli --json output. BISCOTTI_REAL_MIC /
/// BISCOTTI_REAL_SYSTEM: the two tracks. BISCOTTI_REAL_CAPTURE: optional
/// capture file. BISCOTTI_REAL_FROM/TO: seconds to print. BISCOTTI_REAL_USER:
/// the user's name as the meeting shows it. BISCOTTI_REAL_START: the
/// recording's start (ISO 8601), so capture times line up as in the app.
struct RealMeetingNamingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BISCOTTI_REAL_JSON"] != nil))
    @MainActor
    func printNaming() throws {
        let env = ProcessInfo.processInfo.environment
        let data = try Data(contentsOf: URL(fileURLWithPath: #require(env["BISCOTTI_REAL_JSON"])))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(TranscriptResult.self, from: data)
        let levels = try AudioLevelReader.levels(
            mic: URL(fileURLWithPath: #require(env["BISCOTTI_REAL_MIC"])),
            system: URL(fileURLWithPath: #require(env["BISCOTTI_REAL_SYSTEM"]))
        )
        let timeline = try env["BISCOTTI_REAL_CAPTURE"].map {
            try ParticipantTimelineBuilder.build(
                captureFile: URL(fileURLWithPath: $0),
                recordingStartedAt: env["BISCOTTI_REAL_START"].flatMap { ISO8601DateFormatter().date(from: $0) }
            )
        }
        let fusion = SpeakerFuser.fuse(
            words: result.segments.flatMap { $0.words ?? [] }.map {
                FusionWord(text: $0.word, start: $0.startTime, end: $0.endTime, probability: $0.probability, clusterID: $0.speakerID)
            },
            levels: levels, timeline: timeline, userName: env["BISCOTTI_REAL_USER"] ?? "Sam Carter",
            voiceSpans: result.speakerSpans.map { VoiceSpan(cluster: $0.speakerID, start: $0.start, end: $0.end) }
        )
        let from = Double(env["BISCOTTI_REAL_FROM"] ?? "0") ?? 0
        let upTo = Double(env["BISCOTTI_REAL_TO"] ?? "100000") ?? 100_000
        print("REPORT", fusion.report.summary)
        let probeWords = result.segments.flatMap { $0.words ?? [] }.map {
            FusionWord(text: $0.word, start: $0.startTime, end: $0.endTime, probability: $0.probability, clusterID: $0.speakerID)
        }.sorted { $0.start < $1.start }
        for line in timeline?.captions ?? [] where line.start >= from - 5 && line.start <= upTo {
            print("CAPTION", String(format: "%6.1f-%6.1f", line.start, line.end), line.name, "|", line.text)
        }
        for word in probeWords where word.start >= from && word.start <= upTo {
            var mic: Float = -999
            var system: Float = -999
            if let levels {
                let lower = Int(max(word.start, word.end - 0.4) / levels.frameSeconds)
                let upper = max(lower + 1, Int(word.end / levels.frameSeconds))
                mic = levels.micDB[min(lower, levels.micDB.count - 1) ..< min(upper, levels.micDB.count)].max() ?? -999
                system = levels.systemDB[min(lower, levels.systemDB.count - 1) ..< min(upper, levels.systemDB.count)].max() ?? -999
            }
            print("WORD", String(format: "%6.2f-%6.2f mic %4.0f sys %4.0f", word.start, word.end, mic, system),
                  word.clusterID ?? -1, word.text)
        }
        for segment in fusion.segments where segment.start >= from && segment.start <= upTo {
            let text = segment.words.map(\.text).joined()
            print("LINE", String(format: "%6.1f", segment.start), segment.speaker, text.prefix(80))
        }
    }
}
