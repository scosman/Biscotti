import Foundation
import Testing
@testable import MeetingDetection

/// Ferdium keeps the mic open all day, so its mic is no signal.
@MainActor
struct AlwaysOnMicTests {
    @Test func ferdiumAndItsHelpersAreIgnored() {
        #expect(MeetingDetector.ignoresMic("org.ferdium.ferdium-app"))
        #expect(MeetingDetector.ignoresMic("org.ferdium.ferdium-app.helper"))
        #expect(MeetingDetector.ignoresMic("org.ferdium.ferdium-app.helper.Renderer"))
    }

    @Test func meetingAppsStillCount() {
        #expect(!MeetingDetector.ignoresMic("com.microsoft.teams2.modulehost"))
        #expect(!MeetingDetector.ignoresMic("us.zoom.xos"))
        #expect(!MeetingDetector.ignoresMic("com.electron.dialpad.helper"))
    }
}
