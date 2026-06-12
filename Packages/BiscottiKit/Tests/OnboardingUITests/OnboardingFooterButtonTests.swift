import BiscottiTestSupport
import Calendar
import DataStore
import Permissions
import Testing
@testable import OnboardingUI

@Suite("OnboardingViewModel — Footer button state")
@MainActor
struct OnboardingFooterButtonTests {
    // MARK: - Welcome & Done always show Continue

    @Test("welcome step shows Continue (never Skip)")
    func welcomeStepShowsContinue() throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)
        #expect(model.currentStep == .welcome)
        #expect(
            model.footerButton(for: .welcome) == .continueButton
        )
    }

    @Test("done step shows Continue (never Skip)")
    func doneStepShowsContinue() throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)
        #expect(
            model.footerButton(for: .done) == .continueButton
        )
    }

    // MARK: - Calendar selection always shows Continue

    @Test("calendar selection step shows Continue (never Skip)")
    func calendarSelectionStepShowsContinue() throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)
        #expect(
            model.footerButton(for: .calendarSelection)
                == .continueButton
        )
    }

    // MARK: - Launch at Login shows custom (No/Yes)

    @Test("launch at login step shows custom footer")
    func launchAtLoginStepShowsCustom() throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)
        #expect(
            model.footerButton(for: .launchAtLogin) == .custom
        )
    }

    // MARK: - Microphone: Skip before grant, Continue after

    @Test("microphone step shows Skip before grant, Continue after")
    func microphoneSkipThenContinue() async throws {
        let fixture = try makeCoreFixture(
            micStatus: .notDetermined,
            micRequestResult: true
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)
        await model.advance() // welcome -> microphone

        // Before granting: should show Skip
        #expect(model.footerButton(for: .microphone) == .skip)
        #expect(model.isCurrentStepComplete == false)

        // Request permission (grants it)
        await model.requestPermission()

        // After granting: should show Continue
        #expect(model.footerButton(for: .microphone) == .continueButton)
        #expect(model.isCurrentStepComplete == true)
    }

    // MARK: - System Audio: Skip before grant, Continue after

    @Test("system audio step shows Skip before grant, Continue after")
    func systemAudioSkipThenContinue() async throws {
        let fixture = try makeCoreFixture(
            micStatus: .notDetermined
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        // Before granting: should show Skip
        #expect(model.footerButton(for: .systemAudio) == .skip)

        // Walk to system audio step and simulate granting
        await model.advance() // welcome -> microphone
        await model.advance() // microphone -> systemAudio

        // System audio may or may not be granted by the fake;
        // verify the footer tracks the granted state correctly
        let expectedButton: OnboardingViewModel.FooterButton =
            model.systemAudioGranted ? .continueButton : .skip
        #expect(
            model.footerButton(for: .systemAudio) == expectedButton
        )
    }

    // MARK: - Calendar: Skip before grant, Continue after

    @Test("calendar step shows Skip before grant, Continue after")
    func calendarSkipThenContinue() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .notDetermined
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        // Before granting: should show Skip
        #expect(model.footerButton(for: .calendar) == .skip)

        // Walk to calendar step
        await model.advance() // welcome -> microphone
        await model.skip() // -> systemAudio
        await model.skip() // -> calendar

        // Still not granted
        #expect(model.footerButton(for: .calendar) == .skip)
        #expect(model.isCurrentStepComplete == false)

        // Simulate the OS granting access: update the fake event
        // store's auth status before calling requestPermission
        // (CalendarService re-reads authorizationStatus() after the
        // request call).
        fixture.fakeEventStore.authStatus = .authorized
        await model.requestPermission()
        #expect(model.calendarGranted == true)
        #expect(model.footerButton(for: .calendar) == .continueButton)
        #expect(model.isCurrentStepComplete == true)
    }

    // MARK: - Notifications: Skip before grant, Continue after

    @Test("notifications step shows Skip before grant, Continue after")
    func notificationsSkipThenContinue() async throws {
        let fakeNotif = FakeNotificationAuthorizer(
            status: .notDetermined, requestResult: true
        )
        let fixture = try makeCoreFixture(
            notificationAuthorizer: fakeNotif
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        // Before granting: should show Skip
        #expect(model.footerButton(for: .notifications) == .skip)

        // Walk to notifications step
        await model.advance() // welcome -> microphone
        await model.skip() // -> systemAudio
        await model.skip() // -> calendar
        await model.skip() // -> notifications

        #expect(model.currentStep == .notifications)
        #expect(model.footerButton(for: .notifications) == .skip)

        // Request permission (grants it via fake authorizer)
        await model.requestPermission()
        #expect(model.notificationsGranted == true)
        #expect(
            model.footerButton(for: .notifications)
                == .continueButton
        )
        #expect(model.isCurrentStepComplete == true)
    }

    // MARK: - Model download: Skip before download, Continue after

    @Test("model download step shows Skip before download, Continue after")
    func modelDownloadSkipThenContinue() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        // Before downloading: should show Skip
        #expect(model.footerButton(for: .modelDownload) == .skip)

        // Walk to model download step
        await model.advance() // welcome -> microphone
        await model.skip() // -> systemAudio
        await model.skip() // -> calendar
        await model.skip() // -> notifications
        await model.skip() // -> modelDownload

        #expect(model.currentStep == .modelDownload)
        #expect(model.footerButton(for: .modelDownload) == .skip)
        #expect(model.isCurrentStepComplete == false)

        // Download models
        await model.startDownload()
        #expect(model.downloadComplete == true)
        #expect(
            model.footerButton(for: .modelDownload)
                == .continueButton
        )
        #expect(model.isCurrentStepComplete == true)
    }

    // MARK: - Already-granted permission shows Continue on entry

    @Test("already-granted mic shows Continue on step entry")
    func alreadyGrantedMicShowsContinue() async throws {
        let fixture = try makeCoreFixture(
            micStatus: .authorized
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        // Before entering mic step, result is .notDetermined
        #expect(model.footerButton(for: .microphone) == .skip)

        // Advance into microphone step -- syncLivePermissionState fires
        await model.advance() // welcome -> microphone
        #expect(model.microphoneGranted == true)
        #expect(
            model.footerButton(for: .microphone) == .continueButton
        )
        #expect(model.isCurrentStepComplete == true)
    }
}
