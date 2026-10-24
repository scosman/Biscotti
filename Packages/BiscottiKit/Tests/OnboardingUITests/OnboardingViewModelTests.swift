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

    @Test("startTranscriptionDownload triggers speech engine download")
    func startTranscriptionDownload() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        await model.advance() // welcome -> permissions
        await model.skip() // -> modelDownload

        #expect(model.currentStep == .modelDownload)

        await model.startTranscriptionDownload()
        // FakeTranscriber's download succeeds immediately, so
        // the engine should now be downloaded and target ready.
        #expect(model.transcriptionReady == true)
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

        // Reset
        model.resetForReplay()

        #expect(model.currentStep == .welcome)
        #expect(model.microphoneResult == .notDetermined)
        #expect(model.systemAudioResult == .notRequested)
        #expect(model.calendarResult == .notDetermined)
        #expect(model.notificationsGranted == false)
        #expect(model.calendarGroups.isEmpty)
        #expect(model.enabledCalendarIDs == nil)
        #expect(model.isPreparingModelStep == false)
        #expect(model.showVariantSheet == false)
        #expect(model.showSpeechSheet == false)
        #expect(model.showConnectCalendarSheet == false)
    }
}

// MARK: - Calendar reload on foreground

@Suite("OnboardingViewModel -- calendar reload")
@MainActor
struct OnboardingCalendarReloadTests {
    @Test("reloadCalendars fetches calendars when on calendarSelection step")
    func reloadCalendarsOnCalendarStep() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .authorized,
            calendarInfos: []
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        // Navigate to calendar selection step
        await model.advance() // welcome -> permissions
        await model.requestCalendar()
        await model.advance() // permissions -> calendarSelection

        #expect(model.currentStep == .calendarSelection)
        #expect(model.calendarGroups.isEmpty)

        // Simulate adding a calendar externally
        fixture.fakeEventStore.calendarInfos = [
            CalendarInfo(
                id: "c1", title: "Work",
                colorHex: "#0066CC", sourceTitle: "Google"
            )
        ]

        await model.reloadCalendars()

        #expect(model.calendarGroups.count == 1)
        #expect(model.calendarGroups[0].calendars[0].title == "Work")
    }

    @Test("reloadCalendars is a no-op when not on calendarSelection step")
    func reloadCalendarsNoOpOnOtherSteps() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)

        // Stay on welcome step
        #expect(model.currentStep == .welcome)

        // Even if there are calendars available, reload should not fetch
        fixture.fakeEventStore.calendarInfos = [
            CalendarInfo(
                id: "c1", title: "Work",
                colorHex: "#0066CC", sourceTitle: "Google"
            )
        ]

        await model.reloadCalendars()
        #expect(model.calendarGroups.isEmpty)
    }
}

// MARK: - Persist target on advance (functional spec §4.3)

@Suite("OnboardingViewModel -- persist target on advance")
@MainActor
struct OnboardingPersistTargetTests {
    @Test("advance from modelDownload persists target when selection is empty")
    func advancePersistsTarget() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            modelDownloaded: true,
            whisperPresent: true,
            speakerIDPresent: true
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)
        await model.advance() // welcome -> permissions
        await model.skip() // -> modelDownload

        // No explicit selection has been made
        #expect(fixture.speechEngines.selection == nil)

        // Advance (Continue) should persist the target
        await model.advance()
        #expect(model.currentStep == .done)
        #expect(fixture.speechEngines.selection != nil)
    }

    @Test("skip from modelDownload does not persist target")
    func skipDoesNotPersistTarget() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)
        await model.advance() // welcome -> permissions
        await model.skip() // -> modelDownload

        // No explicit selection
        #expect(fixture.speechEngines.selection == nil)

        // Skip should NOT persist the target
        await model.skip()
        #expect(model.currentStep == .done)
        #expect(fixture.speechEngines.selection == nil)
    }

    @Test("advance does not overwrite existing selection")
    func advanceDoesNotOverwriteExisting() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            modelDownloaded: true,
            whisperPresent: true,
            speakerIDPresent: true
        )
        defer { fixture.cleanup() }

        // Pre-set an explicit selection via the store
        try await fixture.store.updateSettings { $0.sttEngineSelection = "whisper" }
        await fixture.speechEngines.refresh()

        let model = OnboardingViewModel(core: fixture.core)
        await model.advance() // welcome -> permissions
        await model.skip() // -> modelDownload

        #expect(fixture.speechEngines.selection != nil)

        // Advance should not change the existing selection
        await model.advance()
        #expect(model.currentStep == .done)

        let settings = try await fixture.store.settings()
        #expect(settings.sttEngineSelection == "whisper")
    }
}

// MARK: - Speech options link and transcription label

@Suite("OnboardingViewModel -- speech engine UI properties")
@MainActor
struct OnboardingSpeechUIPropertyTests {
    @Test("showsSpeechOptionsLink is true when Apple Speech available")
    func showsLinkWhenAppleAvailable() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            appleAvailability: .available,
            appleLocales: ["en_US"],
            appleEquivalent: "en_US"
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)
        await model.advance() // welcome -> permissions (triggers refresh)
        await model.skip() // -> modelDownload

        #expect(model.showsSpeechOptionsLink == true)
    }

    @Test("showsSpeechOptionsLink is false when Apple Speech unavailable")
    func hidesLinkWhenAppleUnavailable() async throws {
        // Default fixture on macOS 15: Apple is unavailable
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)
        await model.advance()
        await model.skip()

        #expect(model.showsSpeechOptionsLink == false)
    }

    @Test("showsSpeechOptionsLink is false when Apple requires OS update")
    func hidesLinkWhenRequiresOSUpdate() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            appleAvailability: .requiresOSUpdate(currentMajor: 15)
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)
        await model.advance()
        await model.skip()

        #expect(model.showsSpeechOptionsLink == false)
    }

    @Test("transcriptionLineText returns summary label from SpeechEngineManager")
    func transcriptionLineTextMatchesSummaryLabel() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)
        await model.advance()
        await model.skip()

        #expect(model.transcriptionLineText == fixture.speechEngines.summaryLabel)
        #expect(!model.transcriptionLineText.isEmpty)
    }

    @Test("transcriptionLineText reflects Apple engine when targeted")
    func transcriptionLineTextApple() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            appleAvailability: .available,
            appleLocales: ["en_US"],
            appleEquivalent: "en_US",
            appleInstalled: ["en_US"]
        )
        defer { fixture.cleanup() }

        let model = OnboardingViewModel(core: fixture.core)
        await model.advance()
        await model.skip()

        // After refresh, Apple target is auto-selected when available
        #expect(model.transcriptionLineText.contains("Apple Speech"))
    }
}
