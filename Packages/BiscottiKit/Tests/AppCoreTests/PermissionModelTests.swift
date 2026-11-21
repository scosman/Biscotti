import BiscottiTestSupport
import Permissions
import Testing
@testable import AppCore

/// One permission model for the launch prompt and Settings.
@MainActor
struct PermissionModelTests {
    @Test func statusesMapTheSameWayForEveryPermission() async throws {
        let fix = try makeCoreFixture(micStatus: .denied, testName: "PermissionModelTests")
        defer { fix.cleanup() }
        await fix.core.permissions.refresh()
        #expect(fix.core.status(of: .microphone) == .blocked)
        #expect(AppPermissionStatus.blocked.title == "Off in System Settings")
        #expect(AppPermissionStatus.notAsked.title == "Not granted")
    }

    @Test func deniedMicrophoneIsRaisedButAnIgnoredCalendarIsNot() async throws {
        let fix = try makeCoreFixture(
            micStatus: .denied, calendarAuthStatus: .denied, testName: "PermissionModelTests"
        )
        defer { fix.cleanup() }
        await fix.core.refreshAllPermissions()
        let needed = fix.core.permissionsNeedingAttention
        #expect(needed.contains(.microphone))
        #expect(!needed.contains(.calendar))
        // Tests use the ephemeral automation store: capture is off, so
        // Accessibility isn't asked for.
        #expect(!needed.contains(.accessibility))
    }

    @Test func thePromptListRoundTripsThroughTheStore() throws {
        let fix = try makeCoreFixture(testName: "PermissionModelTests")
        defer { fix.cleanup() }
        fix.core.launchPermissionPrompt = [.microphone, .accessibility]
        #expect(fix.core.launchPermissionPrompt == [.microphone, .accessibility])
        fix.core.launchPermissionPrompt = []
        #expect(fix.core.automation.missingPermissions.isEmpty)
    }
}
