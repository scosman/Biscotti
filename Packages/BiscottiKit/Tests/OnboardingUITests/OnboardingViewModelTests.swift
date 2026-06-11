import BiscottiTestSupport
import Calendar
import DataStore
import Permissions
import Testing
@testable import OnboardingUI

@Suite("OnboardingViewModel")
@MainActor
struct OnboardingViewModelTests {
    // MARK: - Step advancement

    @Test("advances through all steps when calendar authorized")
    func onboardingAdvancesThroughAllSteps() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .authorized
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        #expect(model.currentStep == .welcome)
        await model.advance()
        #expect(model.currentStep == .microphone)
        await model.advance()
        #expect(model.currentStep == .systemAudio)
        await model.advance()
        #expect(model.currentStep == .calendar)
        // Calendar authorized (synced from live state) -> calendarSelection
        await model.advance()
        #expect(model.currentStep == .calendarSelection)
        await model.advance()
        #expect(model.currentStep == .notifications)
        await model.advance()
        #expect(model.currentStep == .modelDownload)
        await model.advance()
        #expect(model.currentStep == .launchAtLogin)
        await model.advance()
        #expect(model.currentStep == .done)
    }

    @Test("advances skipping calendar selection when denied")
    func onboardingAdvancesSkippingCalendarSelection() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        #expect(model.currentStep == .welcome)
        await model.advance()
        #expect(model.currentStep == .microphone)
        await model.advance()
        #expect(model.currentStep == .systemAudio)
        await model.advance()
        #expect(model.currentStep == .calendar)
        // Calendar denied (synced from live state) -> skip calendarSelection
        await model.advance()
        #expect(model.currentStep == .notifications)
        await model.advance()
        #expect(model.currentStep == .modelDownload)
        await model.advance()
        #expect(model.currentStep == .launchAtLogin)
        await model.advance()
        #expect(model.currentStep == .done)
    }

    @Test("skip skips permission without requesting")
    func onboardingSkipSkipsPermission() async throws {
        let fixture = try makeCoreFixture(
            micStatus: .notDetermined,
            micRequestResult: false
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)
        // microphoneResult starts as .notDetermined

        await model.advance() // welcome -> microphone
        #expect(model.currentStep == .microphone)
        await model.skip() // skip microphone -> systemAudio
        #expect(model.currentStep == .systemAudio)
        // Mic was not requested -- state stays .notDetermined
        #expect(model.microphoneResult == .notDetermined)
    }

    @Test("calendar selection shown when granted")
    func onboardingCalendarSelectionShownWhenGranted() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .authorized,
            calendarInfos: [
                CalendarInfo(
                    id: "c1", title: "Work",
                    colorHex: "#0066CC", sourceTitle: "iCloud"
                )
            ]
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        // Walk to calendar step
        await model.advance() // welcome -> microphone
        await model.skip() // -> systemAudio
        await model.skip() // -> calendar

        #expect(model.currentStep == .calendar)

        // Request calendar access (already authorized)
        await model.requestPermission()
        #expect(model.calendarResult == .authorized)

        // Advance should go to calendarSelection
        await model.advance()
        #expect(model.currentStep == .calendarSelection)
    }

    @Test("calendar selection skipped when denied")
    func onboardingCalendarSelectionSkippedWhenDenied() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        // Walk to calendar step
        await model.advance() // welcome -> microphone
        await model.skip() // -> systemAudio
        await model.skip() // -> calendar

        // Calendar is denied, so advance should skip selection
        await model.advance()
        #expect(model.currentStep == .notifications)
    }

    @Test("model download is skippable")
    func onboardingModelDownloadSkippable() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        // Walk to modelDownload step
        await model.advance() // welcome -> microphone
        await model.skip() // -> systemAudio
        await model.skip() // -> calendar
        await model.skip() // -> notifications
        await model.skip() // -> modelDownload

        #expect(model.currentStep == .modelDownload)
        await model.skip()
        #expect(model.currentStep == .launchAtLogin)
    }

    @Test("model download sets isDownloading and updates status")
    func onboardingModelDownloadProgress() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        // Walk to modelDownload step
        await model.advance() // welcome -> microphone
        await model.skip() // -> systemAudio
        await model.skip() // -> calendar
        await model.skip() // -> notifications
        await model.skip() // -> modelDownload

        await model.startDownload()
        // FakeTranscriber's ensureModelsDownloaded succeeds immediately
        #expect(model.downloadComplete == true)
        #expect(model.isDownloading == false)
    }

    @Test("completeOnboarding calls core.completeOnboarding")
    func onboardingCompletePersistsFlag() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        // Mark onboarding as not complete initially
        try await fixture.store.updateSettings { settings in
            settings.onboardingComplete = false
        }

        let model = OnboardingViewModel(core: fixture.core)
        await model.completeOnboarding()

        // Verify the flag is persisted
        let settings = try await fixture.store.settings()
        #expect(settings.onboardingComplete == true)
    }

    @Test("progress index maps correctly for each step")
    func onboardingProgressIndexMapsCorrectly() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        #expect(model.progressIndex == 0) // welcome
        await model.advance()
        #expect(model.progressIndex == 1) // microphone
        await model.skip()
        #expect(model.progressIndex == 2) // systemAudio
        await model.skip()
        #expect(model.progressIndex == 3) // calendar
        await model.skip()
        #expect(model.progressIndex == 4) // notifications
        await model.skip()
        #expect(model.progressIndex == 5) // modelDownload
        await model.skip()
        #expect(model.progressIndex == 6) // launchAtLogin
        await model.skip()
        #expect(model.progressIndex == 7) // done
    }

    @Test("disk check surfaces warning when insufficient")
    func onboardingDiskCheckSurfacesWarning() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        // Inject low disk space (1 MB -- well below the 2000 MB threshold)
        let lowDiskModel = OnboardingViewModel(
            core: fixture.core,
            availableDiskBytes: { 1_048_576 }
        )

        // Walk to the model download step (advance triggers checkDiskSpace)
        await lowDiskModel.advance() // welcome -> microphone
        await lowDiskModel.skip() // -> systemAudio
        await lowDiskModel.skip() // -> calendar
        await lowDiskModel.skip() // -> notifications
        await lowDiskModel.skip() // -> modelDownload (checkDiskSpace runs here)

        #expect(lowDiskModel.hasSufficientDisk == false)

        // Verify the default (plenty of disk) works too
        let okModel = OnboardingViewModel(
            core: fixture.core,
            availableDiskBytes: { 100_000_000_000 }
        )
        await okModel.advance()
        await okModel.skip()
        await okModel.skip()
        await okModel.skip()
        await okModel.skip()

        #expect(okModel.hasSufficientDisk == true)
    }

    // MARK: - Calendar selection

    @Test("calendar grouping works correctly")
    func calendarGrouping() {
        let infos = [
            CalendarInfo(
                id: "c1", title: "Work",
                colorHex: "#0066CC", sourceTitle: "iCloud"
            ),
            CalendarInfo(
                id: "c2", title: "Family",
                colorHex: "#33CC33", sourceTitle: "iCloud"
            ),
            CalendarInfo(
                id: "c3", title: "Team",
                colorHex: "#CC0000", sourceTitle: "Google"
            )
        ]
        let groups = OnboardingViewModel.groupCalendars(infos)
        #expect(groups.count == 2)
        #expect(groups[0].sourceTitle == "Google")
        #expect(groups[1].sourceTitle == "iCloud")
        #expect(groups[1].calendars.count == 2)
    }

    @Test("all calendars enabled when nil")
    func calendarAllEnabledWhenNil() throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)
        #expect(model.isCalendarEnabled("any-id") == true)
    }

    @Test("total steps is 8")
    func totalStepsIs8() throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)
        #expect(model.totalSteps == 8)
    }
}
