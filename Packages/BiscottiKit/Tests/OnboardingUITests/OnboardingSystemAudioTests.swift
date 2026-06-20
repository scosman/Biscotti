import BiscottiTestSupport
import Permissions
import Testing
@testable import OnboardingUI

@Suite("OnboardingViewModel -- System audio permission")
@MainActor
struct OnboardingSystemAudioTests {
    // MARK: - Validating flag

    @Test("requestSystemAudio toggles isValidating")
    func requestSystemAudioTogglesValidating() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        // Walk to permissions step
        await model.advance() // welcome -> permissions

        #expect(model.isValidatingSystemAudio == false)

        // Request triggers probe
        await model.requestSystemAudio()

        // After completion, validating is false
        #expect(model.isValidatingSystemAudio == false)
        // Probe was called
        #expect(fixture.fakeRecorder.backing.probeSystemAudioWithToneCalled == true)
    }

    @Test("system audio result updates to approved on successful probe")
    func systemAudioApprovedOnSuccessfulProbe() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        fixture.fakeRecorder.backing.probeResult = true

        let model = OnboardingViewModel(core: fixture.core)
        await model.advance() // welcome -> permissions

        await model.requestSystemAudio()

        #expect(model.systemAudioResult == .approved)
        #expect(model.systemAudioGranted == true)
    }

    @Test("system audio result stays requestedNotVerified on failed probe")
    func systemAudioRequestedNotVerifiedOnFailedProbe() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        fixture.fakeRecorder.backing.probeResult = false

        let model = OnboardingViewModel(core: fixture.core)
        await model.advance() // welcome -> permissions

        await model.requestSystemAudio()

        #expect(model.systemAudioResult == .requestedNotVerified)
        #expect(model.systemAudioGranted == false)
    }

    // MARK: - No Validate button (implicit: no action for approved)

    @Test("approved state shows Continue on permissions step")
    func approvedStateShowsContinueForSystemAudio() async throws {
        let fakeNotif = FakeNotificationAuthorizer(
            status: .notDetermined, requestResult: true
        )
        let fixture = try makeCoreFixture(
            micStatus: .authorized,
            calendarAuthStatus: .authorized,
            notificationAuthorizer: fakeNotif
        )
        defer { fixture.cleanup() }
        fixture.fakeRecorder.backing.probeResult = true

        let model = OnboardingViewModel(core: fixture.core)
        await model.advance() // welcome -> permissions

        // Grant all to check footer state
        await model.requestSystemAudio()
        #expect(model.systemAudioGranted == true)

        await model.requestNotifications()

        // All granted -> Continue
        #expect(model.isCurrentStepComplete == true)
        #expect(model.footerButton(for: .permissions) == .continueButton)
    }

    // MARK: - Non-blocking (Continue/Skip always available)

    @Test("permissions step is non-blocking: skip always works")
    func permissionsNonBlockingSkip() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)
        await model.advance() // welcome -> permissions

        #expect(model.currentStep == .permissions)

        // Skip without requesting any permission
        await model.skip()
        #expect(model.currentStep == .modelDownload)
    }

    @Test("permissions step is non-blocking: advance works even if not all approved")
    func permissionsNonBlockingAdvance() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)
        await model.advance() // welcome -> permissions

        // Advance without requesting (footer shows Skip, but advance still works)
        await model.advance()
        #expect(model.currentStep == .modelDownload)
    }

    // MARK: - Fix permissions alert

    @Test("fix permissions alert toggles on and off")
    func fixPermissionsAlertToggle() throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        #expect(model.showFixPermissionsAlert == false)
        model.showFixPermissionsAlert = true
        #expect(model.showFixPermissionsAlert == true)
        model.showFixPermissionsAlert = false
        #expect(model.showFixPermissionsAlert == false)
    }

    // MARK: - No auto-probe on step entry

    @Test("entering permissions step does not trigger a probe")
    func noAutoProbeOnStepEntry() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)
        await model.advance() // welcome -> permissions

        #expect(model.currentStep == .permissions)
        #expect(model.isValidatingSystemAudio == false)
        #expect(fixture.fakeRecorder.backing.probeSystemAudioWithToneCalled == false)
    }

    // MARK: - Reset clears system audio state

    @Test("resetForReplay clears system audio validating and alert state")
    func resetClearsSystemAudioState() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)
        await model.advance() // welcome -> permissions

        await model.requestSystemAudio()
        model.showFixPermissionsAlert = true

        model.resetForReplay()

        #expect(model.isValidatingSystemAudio == false)
        #expect(model.showFixPermissionsAlert == false)
        #expect(model.systemAudioResult == .notRequested)
    }
}
