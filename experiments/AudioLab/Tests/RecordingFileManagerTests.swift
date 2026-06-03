import XCTest

@testable import AudioLab

final class RecordingFileManagerTests: XCTestCase {
    func testTimestampFormat() {
        let timestamp = RecordingFileManager.generateTimestamp()
        // Should look like "20260603T143000" -- compact, unambiguous, filesystem-safe
        XCTAssertFalse(timestamp.contains(":"), "Timestamp should not contain colons (filesystem-safe)")
        XCTAssertTrue(timestamp.contains("T"), "Timestamp should contain T separator")
        XCTAssertEqual(timestamp.count, 15, "Timestamp should be exactly 15 chars: yyyyMMddTHHmmss")
        XCTAssertFalse(timestamp.contains("-"), "Compact format has no dashes")
    }

    func testFilePathsHaveCorrectSuffixes() {
        let timestamp = "20240115T143000"
        let paths = RecordingFileManager.filePaths(timestamp: timestamp)

        XCTAssertTrue(
            paths.mic.lastPathComponent.hasSuffix(RecordingFileManager.micSuffix),
            "Mic file should end with \(RecordingFileManager.micSuffix)"
        )
        XCTAssertTrue(
            paths.system.lastPathComponent.hasSuffix(RecordingFileManager.systemSuffix),
            "System file should end with \(RecordingFileManager.systemSuffix)"
        )
    }

    func testFilePathsContainTimestamp() {
        let timestamp = "20240115T143000"
        let paths = RecordingFileManager.filePaths(timestamp: timestamp)

        XCTAssertTrue(paths.mic.lastPathComponent.hasPrefix(timestamp))
        XCTAssertTrue(paths.system.lastPathComponent.hasPrefix(timestamp))
    }

    func testFilePathsAreInRecordingsDirectory() {
        let timestamp = "test-timestamp"
        let paths = RecordingFileManager.filePaths(timestamp: timestamp)
        let dir = RecordingFileManager.recordingsDirectory()

        XCTAssertEqual(paths.mic.deletingLastPathComponent(), dir)
        XCTAssertEqual(paths.system.deletingLastPathComponent(), dir)
    }

    func testMicAndSystemFilesAreDifferent() {
        let paths = RecordingFileManager.filePaths(timestamp: "test")
        XCTAssertNotEqual(paths.mic, paths.system)
    }

    func testFormattedSizeReturnsNonEmpty() {
        let result = RecordingFileManager.formattedSize(1024)
        XCTAssertFalse(result.isEmpty)
    }
}
