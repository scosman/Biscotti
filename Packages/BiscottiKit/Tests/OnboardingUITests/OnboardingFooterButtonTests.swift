import BiscottiTestSupport
import Calendar
import DataStore
import Permissions
import Testing
@testable import OnboardingUI

@Suite("OnboardingViewModel -- Footer button state")
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

    // MARK: - Permissions: Skip until all four granted

    @Test("permissions shows Skip when no permissions granted")
    func permissionsShowsSkipInitially() async throws {
        let fixture = try makeCoreFixture(
            micStatus: .notDetermined,
            calendarAuthStatus: .notDetermined
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)
        await model.advance() // welcome -> permissions

        #expect(model.footerButton(for: .permissions) == .skip)
        #expect(model.isCurrentStepComplete == false)
    }

    @Test("permissions shows Skip when only some permissions granted")
    func permissionsShowsSkipWhenPartiallyGranted() async throws {
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

        let model = OnboardingViewModel(core: fixture.core)
        await model.advance() // welcome -> permissions

        // Grant mic only
        await model.requestMicrophone()
        #expect(model.microphoneGranted == true)
        #expect(model.footerButton(for: .permissions) == .skip)

        // Grant notifications too -- still not all
        await model.requestNotifications()
        #expect(model.notificationsGranted == true)
        #expect(model.footerButton(for: .permissions) == .skip)
    }

    @Test("permissions shows Continue when all four granted")
    func permissionsShowsContinueWhenAllGranted() async throws {
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

        await model.requestMicrophone()
        await model.requestSystemAudio()
        await model.requestCalendar()
        await model.requestNotifications()

        #expect(model.allPermissionsGranted == true)
        #expect(
            model.footerButton(for: .permissions) == .continueButton
        )
        #expect(model.isCurrentStepComplete == true)
    }

    // MARK: - Model download: Skip before download, Continue after

    @Test("model download step shows Skip before download, Continue when both ready")
    func modelDownloadSkipThenContinue() async throws {
        // Language model pre-downloaded so only transcription is needed
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            modelDownloaded: true
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        // Before downloading: should show Skip (transcription not ready)
        #expect(model.footerButton(for: .modelDownload) == .skip)

        // Walk to model download step (prepareModelStep refreshes ModelManager)
        await model.advance() // welcome -> permissions
        await model.skip() // -> modelDownload

        #expect(model.currentStep == .modelDownload)
        // Language is ready (pre-downloaded), but transcription is not yet
        // downloaded via startTranscriptionDownload -- however prepareModelStep
        // probes modelsReady() which succeeds on the FakeTranscriber, so
        // transcriptionDownloaded is true. Both models are ready.
        #expect(model.bothModelsReady == true)
        #expect(
            model.footerButton(for: .modelDownload)
                == .continueButton
        )
        #expect(model.isCurrentStepComplete == true)
    }

    @Test("model download step shows Skip when only transcription ready")
    func modelDownloadSkipWhenOnlyTranscription() async throws {
        // No language model pre-downloaded
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        // Walk to model download step
        await model.advance() // welcome -> permissions
        await model.skip() // -> modelDownload

        // Transcription is ready (FakeTranscriber succeeds on modelsReady),
        // but language model is not downloaded
        #expect(model.transcriptionReady == true)
        #expect(model.languageReady == false)
        #expect(model.footerButton(for: .modelDownload) == .skip)
    }

    // MARK: - Already-granted permission shows Continue on entry

    @Test("already-granted permissions show Continue on permissions step entry")
    func alreadyGrantedShowsContinue() async throws {
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

        // Before entering permissions, result is .notDetermined
        #expect(model.allPermissionsGranted == false)

        // Advance into permissions -- syncLivePermissionState fires for all four
        await model.advance() // welcome -> permissions
        #expect(model.microphoneGranted == true)
        #expect(model.calendarGranted == true)
        #expect(model.notificationsGranted == true)
        #expect(model.systemAudioGranted == true)
        #expect(model.allPermissionsGranted == true)
        #expect(
            model.footerButton(for: .permissions) == .continueButton
        )
        #expect(model.isCurrentStepComplete == true)
    }
}
