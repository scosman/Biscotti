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
    func advancesThroughAllSteps() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .authorized
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        #expect(model.currentStep == .welcome)
        await model.advance()
        #expect(model.currentStep == .permissions)
        // Grant calendar so calendarSelection appears
        await model.requestCalendar()
        await model.advance()
        #expect(model.currentStep == .calendarSelection)
        await model.advance()
        #expect(model.currentStep == .modelDownload)
        await model.advance()
        #expect(model.currentStep == .done)
    }

    @Test("advances skipping calendar selection when denied")
    func advancesSkippingCalendarSelection() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        #expect(model.currentStep == .welcome)
        await model.advance()
        #expect(model.currentStep == .permissions)
        // Calendar denied -> skip calendarSelection
        await model.advance()
        #expect(model.currentStep == .modelDownload)
        await model.advance()
        #expect(model.currentStep == .done)
    }

    @Test("skip skips permission without requesting")
    func skipSkipsPermission() async throws {
        let fixture = try makeCoreFixture(
            micStatus: .notDetermined,
            micRequestResult: false
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        await model.advance() // welcome -> permissions
        #expect(model.currentStep == .permissions)
        // microphoneResult starts as .notDetermined (synced from live state)
        // Skip the entire permissions screen without requesting anything
        await model.skip()
        // Permission was not requested -- state reflects live state only
        #expect(model.microphoneResult == .notDetermined)
    }

    @Test("calendar selection shown when granted")
    func calendarSelectionShownWhenGranted() async throws {
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

        await model.advance() // welcome -> permissions

        #expect(model.currentStep == .permissions)

        // Request calendar access (already authorized via live state sync)
        await model.requestCalendar()
        #expect(model.calendarResult == .authorized)

        // Advance should go to calendarSelection
        await model.advance()
        #expect(model.currentStep == .calendarSelection)
    }

    @Test("calendar selection skipped when denied")
    func calendarSelectionSkippedWhenDenied() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        await model.advance() // welcome -> permissions

        // Calendar is denied, so advance should skip selection
        await model.advance()
        #expect(model.currentStep == .modelDownload)
    }

    @Test("model download is skippable")
    func modelDownloadSkippable() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        await model.advance() // welcome -> permissions
        await model.skip() // -> modelDownload (calendar denied, skips calendarSelection)

        #expect(model.currentStep == .modelDownload)
        await model.skip()
        #expect(model.currentStep == .done)
    }

    @Test("model download sets isDownloading and updates status")
    func modelDownloadProgress() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        await model.advance() // welcome -> permissions
        await model.skip() // -> modelDownload

        #expect(model.currentStep == .modelDownload)

        await model.startDownload()
        // FakeTranscriber's ensureModelsDownloaded succeeds immediately
        #expect(model.downloadComplete == true)
        #expect(model.isDownloading == false)
    }

    @Test("completeOnboarding calls core.completeOnboarding")
    func completePersistsFlag() async throws {
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
    func progressIndexMapsCorrectly() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .authorized
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        #expect(model.progressIndex == 0) // welcome
        await model.advance()
        #expect(model.progressIndex == 1) // permissions
        await model.requestCalendar()
        await model.advance()
        #expect(model.progressIndex == 2) // calendarSelection
        await model.advance()
        #expect(model.progressIndex == 3) // modelDownload
        await model.advance()
        #expect(model.progressIndex == 4) // done
    }

    @Test("progress jumps 40% to 80% when calendar not granted")
    func progressJumpsWhenCalendarNotGranted() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        await model.advance() // welcome -> permissions
        #expect(model.progressIndex == 1) // 40%
        await model.advance() // -> modelDownload (skipping calendarSelection)
        #expect(model.progressIndex == 3) // 80%
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

    @Test("total steps is 5")
    func totalStepsIs5() throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)
        #expect(model.totalSteps == 5)
    }

    // MARK: - Replay reset

    @Test("resetForReplay resets step and all per-step state")
    func resetForReplayResetsEverything() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        // Advance partway through the wizard
        await model.advance() // welcome -> permissions
        await model.skip() // -> modelDownload

        #expect(model.currentStep == .modelDownload)

        // Mutate some state to verify reset clears it
        await model.startDownload()
        #expect(model.downloadComplete == true)

        // Reset
        model.resetForReplay()

        #expect(model.currentStep == .welcome)
        #expect(model.microphoneResult == .notDetermined)
        #expect(model.systemAudioResult == .notRequested)
        #expect(model.calendarResult == .notDetermined)
        #expect(model.notificationsGranted == false)
        #expect(model.calendarGroups.isEmpty)
        #expect(model.enabledCalendarIDs == nil)
        #expect(model.downloadStatus == nil)
        #expect(model.isDownloading == false)
        #expect(model.downloadComplete == false)
        #expect(model.hasSufficientDisk == true)
    }
}
