import BiscottiTestSupport
import Calendar
import DataStore
import Permissions
import Testing
@testable import OnboardingUI

@Suite("OnboardingViewModel — Granted state + Launch at Login")
@MainActor
struct OnboardingGrantedAndLoginTests {
    // MARK: - Granted-state derivation

    @Test("granted state derived from permission result")
    func grantedStateDerivedFromPermissionResult() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        // Initially all not granted
        #expect(model.microphoneGranted == false)
        #expect(model.systemAudioGranted == false)
        #expect(model.calendarGranted == false)

        // Walk to microphone and request
        await model.advance() // welcome -> microphone
        await model.requestPermission()
        #expect(model.microphoneGranted == true)

        // System audio -- the probe may not set authorized in test
        // but we can verify the property reflects systemAudioResult
        #expect(
            model.systemAudioGranted
                == (model.systemAudioResult == .approved)
        )

        // Calendar -- walk to calendar step and request
        await model.advance() // microphone -> systemAudio
        await model.advance() // systemAudio -> calendar
        await model.requestPermission()
        #expect(model.calendarGranted == true)
    }

    @Test("already-granted permissions reflected on step entry")
    func alreadyGrantedOnEntry() async throws {
        // Mic already authorized, calendar already authorized
        let fixture = try makeCoreFixture(
            micStatus: .authorized,
            calendarAuthStatus: .authorized
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        // Before entering mic step, result is .notDetermined
        #expect(model.microphoneGranted == false)

        // Advance into microphone step -- should sync live status
        await model.advance() // welcome -> microphone
        #expect(model.microphoneGranted == true)

        // Advance into calendar step
        await model.advance() // microphone -> systemAudio
        await model.advance() // systemAudio -> calendar
        #expect(model.calendarGranted == true)
    }

    // MARK: - Launch at Login step

    @Test("launch at login step present in sequence")
    func launchAtLoginStepPresentInSequence() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        // Walk to modelDownload
        await model.advance() // welcome -> microphone
        await model.skip() // -> systemAudio
        await model.skip() // -> calendar
        await model.skip() // -> notifications
        await model.skip() // -> modelDownload

        #expect(model.currentStep == .modelDownload)
        await model.advance() // -> launchAtLogin
        #expect(model.currentStep == .launchAtLogin)
        await model.advance() // -> done
        #expect(model.currentStep == .done)
    }

    @Test("launch at login yes persists true to settings")
    func launchAtLoginYesPersists() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        await model.setLaunchAtLogin(true)

        let settings = try await fixture.store.settings()
        #expect(settings.launchAtLogin == true)
    }

    @Test("launch at login no persists false to settings")
    func launchAtLoginNoPersists() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        // Set it to true first
        try await fixture.store.updateSettings { settings in
            settings.launchAtLogin = true
        }

        let model = OnboardingViewModel(core: fixture.core)

        await model.setLaunchAtLogin(false)

        let settings = try await fixture.store.settings()
        #expect(settings.launchAtLogin == false)
    }
}
