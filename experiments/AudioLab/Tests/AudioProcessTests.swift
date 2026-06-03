import CoreAudio
import XCTest

@testable import AudioLab

final class AudioProcessTests: XCTestCase {
    func testKnownMeetingAppIsRecognized() {
        let zoom = AudioProcess(
            id: 1,
            bundleID: "us.zoom.xos",
            pid: 1234,
            isRunningInput: true,
            isRunningOutput: true
        )
        XCTAssertTrue(zoom.isMeetingApp)
        XCTAssertEqual(zoom.displayName, "Zoom")
    }

    func testTeamsIsRecognized() {
        let teams = AudioProcess(
            id: 2,
            bundleID: "com.microsoft.teams2",
            pid: 5678,
            isRunningInput: false,
            isRunningOutput: true
        )
        XCTAssertTrue(teams.isMeetingApp)
        XCTAssertEqual(teams.displayName, "Microsoft Teams")
    }

    func testChromeIsRecognized() {
        let chrome = AudioProcess(
            id: 3,
            bundleID: "com.google.Chrome",
            pid: 9999,
            isRunningInput: true,
            isRunningOutput: true
        )
        XCTAssertTrue(chrome.isMeetingApp)
        XCTAssertEqual(chrome.displayName, "Google Chrome")
    }

    func testUnknownAppIsNotMeetingApp() {
        let unknown = AudioProcess(
            id: 10,
            bundleID: "com.example.someapp",
            pid: 42,
            isRunningInput: false,
            isRunningOutput: true
        )
        XCTAssertFalse(unknown.isMeetingApp)
        XCTAssertEqual(unknown.displayName, "com.example.someapp")
    }

    func testAllKnownBundleIDsHaveDisplayNames() {
        for bundleID in AudioProcess.knownMeetingBundleIDs {
            XCTAssertNotNil(
                AudioProcess.meetingAppNames[bundleID],
                "Missing display name for \(bundleID)"
            )
        }
    }

    func testAllDisplayNamesAreForKnownBundleIDs() {
        for bundleID in AudioProcess.meetingAppNames.keys {
            XCTAssertTrue(
                AudioProcess.knownMeetingBundleIDs.contains(bundleID),
                "Display name for \(bundleID) but not in known set"
            )
        }
    }

    func testRunningStateIsStoredCorrectly() {
        let process = AudioProcess(
            id: 1,
            bundleID: "test",
            pid: 1,
            isRunningInput: true,
            isRunningOutput: false
        )
        XCTAssertTrue(process.isRunningInput)
        XCTAssertFalse(process.isRunningOutput)
    }
}
