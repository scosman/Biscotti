import BiscottiTestSupport
import Permissions
import Testing
@testable import OnboardingUI

@Suite("OnboardingViewModel -- System audio permission")
@MainActor
struct OnboardingSystemAudioTests {
    // MARK: - Validating flag

    @Test("requestPermission on systemAudio toggles isValidating")
    func requestPermissionTogglesValidating() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        // Walk to system audio step
        await model.advance() // welcome -> microphone
        await model.advance() // microphone -> systemAudio

        #expect(model.isValidatingSystemAudio == false)

        // Request triggers probe
        await model.requestPermission()

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
        await model.advance() // welcome -> microphone
        await model.advance() // microphone -> systemAudio

        await model.requestPermission()

        #expect(model.systemAudioResult == .approved)
        #expect(model.systemAudioGranted == true)
    }

    @Test("system audio result stays requestedNotVerified on failed probe")
    func systemAudioRequestedNotVerifiedOnFailedProbe() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        fixture.fakeRecorder.backing.probeResult = false

        let model = OnboardingViewModel(core: fixture.core)
        await model.advance() // welcome -> microphone
        await model.advance() // microphone -> systemAudio

        await model.requestPermission()

        #expect(model.systemAudioResult == .requestedNotVerified)
        #expect(model.systemAudioGranted == false)
    }

    // MARK: - No Validate button (implicit: no action for approved)

    @Test("approved state in onboarding shows no Validate (just granted)")
    func approvedStateNoValidate() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        fixture.fakeRecorder.backing.probeResult = true

        let model = OnboardingViewModel(core: fixture.core)
        await model.advance() // welcome -> microphone
        await model.advance() // microphone -> systemAudio

        // Grant it
        await model.requestPermission()
        #expect(model.systemAudioGranted == true)

        // Verify the step shows Continue (granted), not Skip
        #expect(model.isCurrentStepComplete == true)
        #expect(model.footerButton(for: .systemAudio) == .continueButton)
    }

    // MARK: - Non-blocking (Continue/Skip always available)

    @Test("system audio step is non-blocking: skip always works")
    func systemAudioNonBlockingSkip() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)
        await model.advance() // welcome -> microphone
        await model.advance() // microphone -> systemAudio

        #expect(model.currentStep == .systemAudio)

        // Skip without requesting permission
        await model.skip()
        #expect(model.currentStep == .calendar)
    }

    @Test("system audio step is non-blocking: advance works even if not approved")
    func systemAudioNonBlockingAdvance() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)
        await model.advance() // welcome -> microphone
        await model.advance() // microphone -> systemAudio

        // Advance without requesting (footer shows Skip, but advance still works)
        await model.advance()
        #expect(model.currentStep == .calendar)
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

    @Test("entering system audio step does not trigger a probe")
    func noAutoProbeOnStepEntry() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)
        await model.advance() // welcome -> microphone
        await model.advance() // microphone -> systemAudio

        #expect(model.currentStep == .systemAudio)
        #expect(model.isValidatingSystemAudio == false)
        #expect(fixture.fakeRecorder.backing.probeSystemAudioWithToneCalled == false)
    }

    // MARK: - Reset clears system audio state

    @Test("resetForReplay clears system audio validating and alert state")
    func resetClearsSystemAudioState() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)
        await model.advance() // welcome -> microphone
        await model.advance() // microphone -> systemAudio

        await model.requestPermission()
        model.showFixPermissionsAlert = true

        model.resetForReplay()

        #expect(model.isValidatingSystemAudio == false)
        #expect(model.showFixPermissionsAlert == false)
        #expect(model.systemAudioResult == .notRequested)
    }
}
