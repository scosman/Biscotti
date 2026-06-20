import BiscottiTestSupport
import Calendar
import DataStore
import Permissions
import Testing
@testable import OnboardingUI

@Suite("OnboardingViewModel -- Granted state")
@MainActor
struct OnboardingGrantedStateTests {
    // MARK: - Granted-state derivation

    @Test("granted state derived from permission result")
    func grantedStateDerivedFromPermissionResult() async throws {
        let fixture = try makeCoreFixture(
            micStatus: .notDetermined,
            micRequestResult: true,
            calendarAuthStatus: .notDetermined
        )
        defer { fixture.cleanup() }
        fixture.fakeEventStore.authStatus = .authorized

        let model = OnboardingViewModel(core: fixture.core)

        // Initially all not granted
        #expect(model.microphoneGranted == false)
        #expect(model.systemAudioGranted == false)
        #expect(model.calendarGranted == false)

        // Advance to permissions and request each independently
        await model.advance() // welcome -> permissions

        await model.requestMicrophone()
        #expect(model.microphoneGranted == true)

        // System audio -- the probe may not set authorized in test
        // but we can verify the property reflects systemAudioResult
        #expect(
            model.systemAudioGranted
                == (model.systemAudioResult == .approved)
        )

        await model.requestCalendar()
        #expect(model.calendarGranted == true)
    }

    @Test("already-granted permissions reflected on permissions step entry")
    func alreadyGrantedOnEntry() async throws {
        // Mic already authorized, calendar already authorized
        let fixture = try makeCoreFixture(
            micStatus: .authorized,
            calendarAuthStatus: .authorized
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        // Before entering permissions step, result is .notDetermined
        #expect(model.microphoneGranted == false)

        // Advance into permissions -- should sync live status for all four
        await model.advance() // welcome -> permissions
        #expect(model.microphoneGranted == true)
        #expect(model.calendarGranted == true)
    }

    @Test("syncLivePermissionState syncs all four on permissions step")
    func syncLivePermissionStateAllFour() async throws {
        let fakeNotif = FakeNotificationAuthorizer(
            status: .authorized, requestResult: true
        )
        let fixture = try makeCoreFixture(
            micStatus: .authorized,
            calendarAuthStatus: .authorized,
            notificationAuthorizer: fakeNotif
        )
        defer { fixture.cleanup() }
        // Pre-populate system audio and notifications state so
        // syncLivePermissionState reads them as already-granted.
        fixture.permissions.setSystemAudio(.approved)
        fixture.permissions.noteNotifications(.authorized)

        let model = OnboardingViewModel(core: fixture.core)

        // Advance into permissions -- syncLivePermissionState fires
        await model.advance() // welcome -> permissions

        #expect(model.microphoneGranted == true)
        #expect(model.systemAudioGranted == true)
        #expect(model.calendarGranted == true)
        #expect(model.notificationsGranted == true)
    }

    // MARK: - allPermissionsGranted aggregation

    @Test("allPermissionsGranted is false until all four granted")
    func allPermissionsGrantedAggregation() async throws {
        let fakeNotif = FakeNotificationAuthorizer(
            status: .notDetermined, requestResult: true
        )
        let fixture = try makeCoreFixture(
            micStatus: .notDetermined,
            micRequestResult: true,
            calendarAuthStatus: .notDetermined,
            notificationAuthorizer: fakeNotif
        )
        defer { fixture.cleanup() }
        fixture.fakeRecorder.backing.probeResult = true
        fixture.fakeEventStore.authStatus = .authorized

        let model = OnboardingViewModel(core: fixture.core)
        await model.advance() // welcome -> permissions

        #expect(model.allPermissionsGranted == false)

        await model.requestMicrophone()
        #expect(model.allPermissionsGranted == false)

        await model.requestSystemAudio()
        #expect(model.allPermissionsGranted == false)

        await model.requestCalendar()
        #expect(model.allPermissionsGranted == false)

        await model.requestNotifications()
        #expect(model.allPermissionsGranted == true)
    }

    // MARK: - Navigation branching from permissions

    @Test("advance and skip both branch from permissions based on calendar state")
    func advanceAndSkipBothBranchFromPermissions() async throws {
        // When calendar granted: both advance and skip go to calendarSelection
        let grantedFixture = try makeCoreFixture(
            calendarAuthStatus: .authorized
        )
        defer { grantedFixture.cleanup() }

        let advModel = OnboardingViewModel(core: grantedFixture.core)
        await advModel.advance() // welcome -> permissions
        await advModel.requestCalendar()
        await advModel.advance()
        #expect(advModel.currentStep == .calendarSelection)

        let skipModel = OnboardingViewModel(core: grantedFixture.core)
        await skipModel.advance() // welcome -> permissions
        await skipModel.requestCalendar()
        await skipModel.skip()
        #expect(skipModel.currentStep == .calendarSelection)

        // When calendar denied: both go to modelDownload
        let deniedFixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { deniedFixture.cleanup() }

        let advDenied = OnboardingViewModel(core: deniedFixture.core)
        await advDenied.advance() // welcome -> permissions
        await advDenied.advance()
        #expect(advDenied.currentStep == .modelDownload)

        let skipDenied = OnboardingViewModel(core: deniedFixture.core)
        await skipDenied.advance() // welcome -> permissions
        await skipDenied.skip()
        #expect(skipDenied.currentStep == .modelDownload)
    }
}
