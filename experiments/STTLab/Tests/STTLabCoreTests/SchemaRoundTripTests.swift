import Foundation
import Testing

@testable import STTLabCore

@Suite("Schema JSON round-trip tests")
struct SchemaRoundTripTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    @Test func bundleManifestRoundTrip() throws {
        let original = BundleManifest(
            bundleID: UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!,
            createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
            meetings: ["m01", "m02", "m03"]
        )
        let decoded = try roundTrip(original)
        #expect(decoded == original)
        #expect(decoded.schemaVersion == SchemaVersions.bundle)
    }

    @Test func meetingMetaRoundTrip() throws {
        let original = MeetingMeta(
            meetingID: "m01",
            durationSeconds: 1800.5,
            speakerCount: 3,
            transcriptLanguage: "en",
            appleLocale: "en_US",
            audioSHA256: "abcdef1234567890"
        )
        let decoded = try roundTrip(original)
        #expect(decoded == original)
        #expect(decoded.sampleRate == 16000)
        #expect(decoded.audioFile == "audio.wav")
    }

    @Test func machineInfoRoundTrip() throws {
        let original = MachineInfo(
            hostModel: "Mac14,6",
            chip: "Apple M2 Max",
            memoryBytes: 34_359_738_368,
            osVersion: "Version 15.0 (Build 24A335)",
            osBuild: "24A335"
        )
        let decoded = try roundTrip(original)
        #expect(decoded == original)
    }

    @Test func memoryReportRoundTrip() throws {
        let original = MemoryReport(
            processPeakFootprintBytes: 104_857_600,
            processLifetimePeakBytes: 209_715_200,
            sampleIntervalSeconds: 0.5,
            sampleCount: 120,
            systemProcesses: [
                ProcessMemory(
                    name: "speechsynthesisd", pid: 412,
                    peakFootprintBytes: 52_428_800,
                    lifetimeMaxFootprintBytes: 104_857_600
                )
            ],
            systemProcessesNote: nil
        )
        let decoded = try roundTrip(original)
        #expect(decoded == original)
    }

    @Test func errorInfoRoundTrip() throws {
        let original = ErrorInfo(
            domain: "NSCocoaErrorDomain",
            code: 4,
            description: "The file doesn't exist.",
            debugDescription: "NSCocoaErrorDomain(4)"
        )
        let decoded = try roundTrip(original)
        #expect(decoded == original)
    }

    @Test func timedRunRoundTrip() throws {
        let start = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let end = Date(timeIntervalSinceReferenceDate: 700_001_800)
        let original = TimedRun(start: start, end: end)
        let decoded = try roundTrip(original)
        #expect(decoded == original)
        #expect(decoded.wallSeconds == 1800.0)
    }

    @Test func appleMeetingResultRoundTrip() throws {
        let bundleID = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let original = AppleMeetingResult(
            bundleID: bundleID,
            meetingID: "m01",
            status: .completed,
            requestedLocale: "en_US",
            resolvedLocale: "en_US",
            config: AppleConfig(),
            timing: TimedRun(
                start: Date(timeIntervalSinceReferenceDate: 700_000_000),
                end: Date(timeIntervalSinceReferenceDate: 700_001_800)
            ),
            audioDurationSeconds: 1800.0,
            results: [
                AppleResult(
                    index: 0,
                    rangeStart: CMTimeValue(value: 0, timescale: 1_000_000_000, flags: 1, epoch: 0, seconds: 0),
                    rangeDuration: CMTimeValue(value: 5_000_000_000, timescale: 1_000_000_000, flags: 1, epoch: 0, seconds: 5.0),
                    resultsFinalizationTime: CMTimeValue(value: 5_000_000_000, timescale: 1_000_000_000, flags: 1, epoch: 0, seconds: 5.0),
                    isFinal: true,
                    text: "Hello world",
                    runs: [
                        AppleRun(
                            text: "Hello",
                            charOffset: 0,
                            charLength: 5,
                            timeStart: CMTimeValue(value: 0, timescale: 1_000_000_000, flags: 1, epoch: 0, seconds: 0),
                            timeDuration: CMTimeValue(value: 500_000_000, timescale: 1_000_000_000, flags: 1, epoch: 0, seconds: 0.5),
                            confidence: 0.95,
                            attributesDebug: "audioTimeRange, transcriptionConfidence"
                        ),
                        AppleRun(
                            text: " world",
                            charOffset: 5,
                            charLength: 6,
                            confidence: 0.90,
                            attributesDebug: "transcriptionConfidence"
                        )
                    ],
                    alternatives: [
                        AppleAlternative(text: "Hello World")
                    ]
                )
            ]
        )
        let decoded = try roundTrip(original)
        #expect(decoded == original)
        #expect(decoded.schemaVersion == SchemaVersions.appleResult)
    }

    @Test func runnerSessionRoundTrip() throws {
        let bundleID = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let original = RunnerSession(
            bundleID: bundleID,
            appVersion: "1.0",
            machine: MachineInfo(
                hostModel: "Mac14,6", chip: "Apple M2 Max",
                memoryBytes: 34_359_738_368, osVersion: "Version 15.0", osBuild: "24A335"
            ),
            startedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
            endedAt: Date(timeIntervalSinceReferenceDate: 700_010_000),
            speechTranscriberAvailable: true,
            supportedLocales: ["en_US", "de_DE"],
            force: false,
            meetingsAttempted: ["m01", "m02"],
            meetingsSkipped: ["m03"]
        )
        let decoded = try roundTrip(original)
        #expect(decoded == original)
    }

    @Test func runFileRoundTrip() throws {
        let bundleID = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let session = RunnerSession(
            bundleID: bundleID,
            appVersion: "1.0",
            machine: MachineInfo(
                hostModel: "Mac14,6", chip: "M2", memoryBytes: 16_000_000_000,
                osVersion: "15.0", osBuild: "24A335"
            ),
            startedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
            speechTranscriberAvailable: true
        )
        let original = RunFile(sessions: [session])
        let decoded = try roundTrip(original)
        #expect(decoded == original)
        #expect(decoded.schemaVersion == SchemaVersions.runFile)
    }

    @Test func runStatusAllCases() throws {
        for status in [RunStatus.completed, .failed, .unsupportedLocale] {
            let decoded = try roundTrip(status)
            #expect(decoded == status)
        }
    }
}
