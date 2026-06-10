import Foundation
import ManualTestKit
import Testing

@Suite("AutoChecks pure-function behaviour")
struct CheckOutcomeTests {
    // MARK: - AAC file checks

    @Test("checkAACFilesExist passes when both files exist and are large enough")
    func aacFilesBothPresent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aac_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let mic = dir.appendingPathComponent("mic.aac")
        let sys = dir.appendingPathComponent("system.aac")
        // Write files larger than defaultMinBytes (10 KB)
        let payload = Data(repeating: 0xAA, count: AutoChecks.defaultMinBytes + 1)
        try payload.write(to: mic)
        try payload.write(to: sys)

        let outcome = AutoChecks.checkAACFilesExist(micURL: mic, systemURL: sys)
        #expect(outcome.passed)
        #expect(outcome.detail.contains("Both"))
    }

    @Test("checkAACFilesExist fails when mic file is missing")
    func aacMicMissing() {
        let dir = FileManager.default.temporaryDirectory
        let mic = dir.appendingPathComponent("no_such_mic_\(UUID().uuidString).aac")
        let sys = dir.appendingPathComponent("no_such_sys_\(UUID().uuidString).aac")

        let outcome = AutoChecks.checkAACFilesExist(micURL: mic, systemURL: sys)
        #expect(!outcome.passed)
        #expect(outcome.detail.contains("mic"))
        #expect(outcome.detail.contains("missing"))
    }

    @Test("checkAACFilesExist fails when a file is too small")
    func aacFileTooSmall() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aac_small_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let mic = dir.appendingPathComponent("mic.aac")
        let sys = dir.appendingPathComponent("system.aac")

        let goodPayload = Data(repeating: 0xBB, count: AutoChecks.defaultMinBytes + 1)
        let tinyPayload = Data(repeating: 0xCC, count: 100) // way below threshold

        try goodPayload.write(to: mic)
        try tinyPayload.write(to: sys)

        let outcome = AutoChecks.checkAACFilesExist(micURL: mic, systemURL: sys)
        #expect(!outcome.passed)
        #expect(outcome.detail.contains("too small"))
    }

    // MARK: - Segment-past-duration checks

    @Test("No segments past duration — all within tolerance")
    func segmentsAllWithin() {
        let outcome = AutoChecks.checkNoSegmentPastDuration(
            segmentEndTimes: [5.0, 10.0, 14.9],
            audioDuration: 15.0
        )
        #expect(outcome.passed)
    }

    @Test("Segment exactly at duration passes")
    func segmentAtExactDuration() {
        let outcome = AutoChecks.checkNoSegmentPastDuration(
            segmentEndTimes: [15.0],
            audioDuration: 15.0
        )
        #expect(outcome.passed)
    }

    @Test("Segment within tolerance passes")
    func segmentWithinTolerance() {
        let outcome = AutoChecks.checkNoSegmentPastDuration(
            segmentEndTimes: [15.3],
            audioDuration: 15.0,
            tolerance: AutoChecks.segmentTimeTolerance
        )
        #expect(outcome.passed)
    }

    @Test("Segment past duration + tolerance fails")
    func segmentPastDuration() {
        let outcome = AutoChecks.checkNoSegmentPastDuration(
            segmentEndTimes: [5.0, 10.0, 18.0],
            audioDuration: 15.0
        )
        #expect(!outcome.passed)
        #expect(outcome.detail.contains("1 segment(s)"))
        #expect(outcome.detail.contains("18.0s"))
    }

    @Test("Multiple segments past duration all reported")
    func multipleSegmentsPast() {
        let outcome = AutoChecks.checkNoSegmentPastDuration(
            segmentEndTimes: [5.0, 20.0, 25.0],
            audioDuration: 15.0
        )
        #expect(!outcome.passed)
        #expect(outcome.detail.contains("2 segment(s)"))
    }

    @Test("Empty segment list passes")
    func emptySegments() {
        let outcome = AutoChecks.checkNoSegmentPastDuration(
            segmentEndTimes: [],
            audioDuration: 10.0
        )
        #expect(outcome.passed)
        #expect(outcome.detail.contains("0 segments"))
    }
}
