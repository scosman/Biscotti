import CoreAudio
import Testing
@testable import AudioCapture

@Suite("AudioProcess")
struct AudioProcessTests {
    @Test("known meeting app is recognized")
    func knownMeetingApp() {
        let zoom = AudioProcess(
            id: 1,
            bundleID: "us.zoom.xos",
            pid: 1234,
            isRunningInput: true,
            isRunningOutput: true
        )
        #expect(zoom.isMeetingApp)
        #expect(zoom.displayName == "Zoom")
    }

    @Test("Teams is recognized")
    func teamsRecognized() {
        let teams = AudioProcess(
            id: 2,
            bundleID: "com.microsoft.teams2",
            pid: 5678,
            isRunningInput: false,
            isRunningOutput: true
        )
        #expect(teams.isMeetingApp)
        #expect(teams.displayName == "Microsoft Teams")
    }

    @Test("Chrome is recognized")
    func chromeRecognized() {
        let chrome = AudioProcess(
            id: 3,
            bundleID: "com.google.Chrome",
            pid: 9999,
            isRunningInput: true,
            isRunningOutput: true
        )
        #expect(chrome.isMeetingApp)
        #expect(chrome.displayName == "Google Chrome")
    }

    @Test("unknown app is not a meeting app")
    func unknownApp() {
        let unknown = AudioProcess(
            id: 10,
            bundleID: "com.example.someapp",
            pid: 42,
            isRunningInput: false,
            isRunningOutput: true
        )
        #expect(!unknown.isMeetingApp)
        #expect(unknown.displayName == "com.example.someapp")
    }

    @Test("nil bundleID is not a meeting app")
    func nilBundleID() {
        let process = AudioProcess(
            id: 11,
            bundleID: nil,
            pid: 99,
            isRunningInput: false,
            isRunningOutput: false
        )
        #expect(!process.isMeetingApp)
        #expect(process.displayName == "Unknown (99)")
    }

    @Test("avconferenced is recognized")
    func avconferencedRecognized() {
        let proc = AudioProcess(
            id: 20,
            bundleID: "com.apple.avconferenced",
            pid: 2000,
            isRunningInput: false,
            isRunningOutput: true
        )
        #expect(proc.isMeetingApp)
        #expect(proc.displayName == "avconferenced")
    }

    @Test("WebKit GPU Process is recognized")
    func webKitGPURecognized() {
        let proc = AudioProcess(
            id: 21,
            bundleID: "com.apple.WebKit.GPU",
            pid: 2001,
            isRunningInput: false,
            isRunningOutput: true
        )
        #expect(proc.isMeetingApp)
        #expect(proc.displayName == "WebKit (GPU Process)")
    }

    @Test("all known bundle IDs have display names")
    func allKnownHaveDisplayNames() {
        for bundleID in AudioProcess.knownMeetingBundleIDs {
            #expect(
                AudioProcess.meetingAppNames[bundleID] != nil,
                "Missing display name for \(bundleID)"
            )
        }
    }

    @Test("all display names are for known bundle IDs")
    func allDisplayNamesAreKnown() {
        for bundleID in AudioProcess.meetingAppNames.keys {
            #expect(
                AudioProcess.knownMeetingBundleIDs.contains(bundleID),
                "Display name for \(bundleID) but not in known set"
            )
        }
    }

    @Test("running state is stored correctly")
    func runningState() {
        let process = AudioProcess(
            id: 1,
            bundleID: "test",
            pid: 1,
            isRunningInput: true,
            isRunningOutput: false
        )
        #expect(process.isRunningInput)
        #expect(!process.isRunningOutput)
    }

    @Test("equatable works for matching processes")
    func equatable() {
        let first = AudioProcess(id: 1, bundleID: "test", pid: 10, isRunningInput: true, isRunningOutput: false)
        let same = AudioProcess(id: 1, bundleID: "test", pid: 10, isRunningInput: true, isRunningOutput: false)
        #expect(first == same)

        let different = AudioProcess(id: 2, bundleID: "test", pid: 10, isRunningInput: true, isRunningOutput: false)
        #expect(first != different)
    }
}
