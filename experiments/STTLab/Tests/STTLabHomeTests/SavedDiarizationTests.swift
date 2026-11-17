import Foundation
import SpeakerKit
import STTLabCore
@testable import STTLabHome
import Testing

@Suite("SavedDiarization")
struct SavedDiarizationTests {
    @Test("Round-trip through JSON preserves all fields")
    func roundTrip() throws {
        let saved = SavedDiarization(
            speakerCount: 3,
            totalFrames: 48000,
            frameRate: 16000,
            segments: [
                SavedSpeakerSegment(
                    speaker: .speakerId(0),
                    startFrame: 0,
                    endFrame: 16000,
                    startTime: 0.0,
                    endTime: 1.0
                ),
                SavedSpeakerSegment(
                    speaker: .speakerId(1),
                    startFrame: 16000,
                    endFrame: 32000,
                    startTime: 1.0,
                    endTime: 2.0
                ),
                SavedSpeakerSegment(
                    speaker: .speakerId(2),
                    startFrame: 32000,
                    endFrame: 48000,
                    startTime: 2.0,
                    endTime: 3.0
                )
            ]
        )

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-test-diarization-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try JSONFiles.write(saved, to: tmpURL)
        let decoded: SavedDiarization = try JSONFiles.read(from: tmpURL)

        #expect(decoded == saved)
        #expect(decoded.speakerCount == 3)
        #expect(decoded.segments.count == 3)
        #expect(decoded.segments[0].speaker == .speakerId(0))
        #expect(decoded.segments[1].startFrame == 16000)
    }

    @Test("Rebuild produces correct DiarizationResult")
    func rebuild() {
        let saved = SavedDiarization(
            speakerCount: 2,
            totalFrames: 32000,
            frameRate: 16000,
            segments: [
                SavedSpeakerSegment(
                    speaker: .speakerId(0),
                    startFrame: 0,
                    endFrame: 16000,
                    startTime: 0.0,
                    endTime: 1.0
                ),
                SavedSpeakerSegment(
                    speaker: .speakerId(1),
                    startFrame: 16000,
                    endFrame: 32000,
                    startTime: 1.0,
                    endTime: 2.0
                )
            ]
        )

        let result = saved.rebuild()

        #expect(result.speakerCount == 2)
        #expect(result.totalFrames == 32000)
        #expect(result.frameRate == 16000)
        #expect(result.segments.count == 2)
        #expect(result.segments[0].speaker == .speakerId(0))
        #expect(result.segments[0].startFrame == 0)
        #expect(result.segments[0].endFrame == 16000)
        #expect(result.segments[1].speaker == .speakerId(1))
        #expect(result.segments[1].startFrame == 16000)
        #expect(result.segments[1].endFrame == 32000)
    }

    @Test("DiarizationOutput round-trips through JSON")
    func outputRoundTrip() throws {
        let output = DiarizationOutput(
            meetingID: "m01",
            status: .completed,
            settings: ["strategy": "subsegment"],
            machine: MachineInfo(
                hostModel: "Mac15,3",
                chip: "Apple M4",
                memoryBytes: 16_000_000_000,
                osVersion: "15.1",
                osBuild: "24B83"
            ),
            timing: TimedRun(
                start: Date(timeIntervalSinceReferenceDate: 1000),
                end: Date(timeIntervalSinceReferenceDate: 1060)
            ),
            audioDurationSeconds: 1800,
            diarization: SavedDiarization(
                speakerCount: 2,
                totalFrames: 32000,
                frameRate: 16000,
                segments: [
                    SavedSpeakerSegment(
                        speaker: .speakerId(0),
                        startFrame: 0,
                        endFrame: 16000,
                        startTime: 0.0,
                        endTime: 1.0
                    )
                ]
            ),
            timingsDescription: "test timings"
        )

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sttlab-test-diaroutput-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try JSONFiles.write(output, to: tmpURL)
        let decoded: DiarizationOutput = try JSONFiles.read(from: tmpURL)

        #expect(decoded == output)
        #expect(decoded.meetingID == "m01")
        #expect(decoded.status == .completed)
        #expect(decoded.diarization?.speakerCount == 2)
        #expect(decoded.timingsDescription == "test timings")
    }

    @Test("SpeakerInfo Codable round-trip for all cases")
    func speakerInfoCodable() throws {
        let cases: [SpeakerInfo] = [
            .speakerId(0),
            .speakerId(5),
            .noMatch,
            .multiple([1, 2, 3])
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for info in cases {
            let data = try encoder.encode(info)
            let decoded = try decoder.decode(SpeakerInfo.self, from: data)
            #expect(decoded == info)
        }
    }
}
