import Foundation
import Testing
@testable import UICapture

/// Capture headers keep milliseconds, and older files with
/// whole seconds still read.
struct CaptureDateTests {
    private static func headerLine(started: String, recording: String) -> Data {
        Data("""
        {"data":{"formatVersion":1,"hostApp":"test","macOSVersion":"test","recordingStartedAt":"\(recording)",\
        "startUptime":1,"startedAt":"\(started)","targets":[]},"type":"header"}
        """.utf8)
    }

    @Test func millisecondsSurviveARoundTrip() throws {
        let line = Self.headerLine(started: "2026-11-20T17:08:18.125Z", recording: "2026-11-20T17:08:17.250Z")
        guard case let .header(header) = try CaptureCoding.decodeLine(line) else {
            Issue.record("not a header")
            return
        }
        let gap = try header.startedAt.timeIntervalSince(#require(header.recordingStartedAt))
        #expect(abs(gap - 0.875) < 0.000_1)
        let written = try #require(String(bytes: CaptureCoding.encodeLine(.header(header)), encoding: .utf8))
        #expect(written.contains("17:08:17.250Z"))
    }

    @Test func wholeSecondFilesStillRead() throws {
        let line = Self.headerLine(started: "2026-11-20T17:08:18Z", recording: "2026-11-20T17:08:17Z")
        guard case let .header(header) = try CaptureCoding.decodeLine(line) else {
            Issue.record("not a header")
            return
        }
        #expect(header.recordingStartedAt != nil)
    }
}
