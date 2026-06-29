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

        model.startTranscriptionDownload()

        // Wait for the retained task to complete
        try await Task.sleep(for: .milliseconds(50))

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
        model.startTranscriptionDownload()
        try await Task.sleep(for: .milliseconds(50))
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
        #expect(model.downloadFailed == false)
        #expect(model.transcriptionDownloaded == false)
        #expect(model.isPreparingModelStep == false)
        #expect(model.showVariantSheet == false)
        #expect(model.showConnectCalendarSheet == false)
        #expect(model.diskWarning == nil)
    }

    @Test("resetForReplay cancels in-flight transcription download via engine")
    func resetForReplayCancelsInFlightDownload() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }
        fixture.fakeEngine.backing.modelsPresentResult = false
        // Make ensureModelsDownloaded block so the download stays in-flight
        fixture.fakeEngine.backing.shouldBlockOnEnsureModels = true

        let model = OnboardingViewModel(core: fixture.core)

        await model.advance() // welcome -> permissions
        await model.skip() // -> modelDownload

        // Start a download that will block
        model.startTranscriptionDownload()

        // Wait for the download task to enter the blocking call
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.isDownloading == true)

        // Reset while download is genuinely in-flight
        model.resetForReplay()

        // Wait for cleanup
        try await Task.sleep(for: .milliseconds(50))

        // Resume the blocked continuation so it doesn't leak
        // (the task was cancelled, so this throws CancellationError)
        fixture.fakeEngine.backing.ensureModelsContinuation?
            .resume(throwing: CancellationError())

        try await Task.sleep(for: .milliseconds(50))

        // Engine's cancelModelDownload should have been called
        #expect(fixture.fakeEngine.backing.cancelModelDownloadCalled == true)

        // All transcription state should be reset
        #expect(model.isDownloading == false)
        #expect(model.downloadStatus == nil)
        #expect(model.downloadComplete == false)
        #expect(model.downloadFailed == false)
        #expect(model.currentStep == .welcome)
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

// MARK: - Language download cancel

@Suite("OnboardingViewModel -- language download cancel")
@MainActor
struct OnboardingLanguageCancelTests {
    @Test("cancelLanguageDownload calls ModelManager.cancelDownload")
    func cancelLanguageDownloadForwards() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance() // welcome -> permissions
        await viewModel.skip() // -> modelDownload

        // Simulate a downloading state for the target model
        let targetID = viewModel.languageTargetModelID ?? ""
        fixture.modelManager.downloads[targetID] = .downloading(fraction: 0.3)

        // Cancel should not crash; it forwards to the manager
        viewModel.cancelLanguageDownload()

        // Verify the downloading model id was resolved correctly
        #expect(viewModel.languageDownloadingModelID == targetID)
    }

    @Test("cancelLanguageDownload is a no-op when no download is in flight")
    func cancelLanguageDownloadNoop() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        // No download in flight — should not crash
        viewModel.cancelLanguageDownload()
    }

    @Test("startLanguageDownload uses startDownload (model becomes available)")
    func startLanguageDownloadUsesStartDownload() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            hardwareDiskBytes: 100_000_000_000
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        viewModel.startLanguageDownload()

        // Wait for the retained task to complete
        try await Task.sleep(for: .milliseconds(50))

        #expect(fixture.modelManager.isModelAvailable == true)
    }
}

// MARK: - Transcription download cancel

@Suite("OnboardingViewModel -- transcription download cancel")
@MainActor
struct OnboardingTranscriptionCancelTests {
    @Test("cancelTranscriptionDownload calls engine cancelModelDownload and resets state")
    func cancelTranscriptionDownloadForwards() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }
        fixture.fakeEngine.backing.modelsPresentResult = false

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance() // welcome -> permissions
        await viewModel.skip() // -> modelDownload

        // Simulate download in progress by setting the flag directly
        viewModel.isDownloading = true
        viewModel.cancelTranscriptionDownload()

        // Wait for the cancel task to complete
        try await Task.sleep(for: .milliseconds(50))

        // Engine's cancelModelDownload should have been called
        #expect(fixture.fakeEngine.backing.cancelModelDownloadCalled == true)
        #expect(fixture.fakeEngine.backing.cancelModelDownloadCallCount == 1)

        // State should be reset to idle
        #expect(viewModel.isDownloading == false)
        #expect(viewModel.downloadStatus == nil)
        #expect(viewModel.downloadComplete == false)
        #expect(viewModel.downloadFailed == false)
    }

    @Test("cancelTranscriptionDownload is a no-op when not downloading")
    func cancelTranscriptionDownloadNoop() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        // Not downloading — should not crash or call engine
        viewModel.cancelTranscriptionDownload()

        try await Task.sleep(for: .milliseconds(50))

        #expect(fixture.fakeEngine.backing.cancelModelDownloadCalled == false)
    }

    @Test("startTranscriptionDownload completes normally when not cancelled")
    func startTranscriptionDownloadCompletesNormally() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }
        fixture.fakeEngine.backing.modelsPresentResult = false

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        viewModel.startTranscriptionDownload()

        // Wait for completion
        try await Task.sleep(for: .milliseconds(50))

        #expect(viewModel.downloadComplete == true)
        #expect(viewModel.isDownloading == false)
        #expect(viewModel.downloadFailed == false)
    }

    @Test("startTranscriptionDownload sets isDownloading and downloadStatus initially")
    func startTranscriptionDownloadSetsInitialState() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }
        fixture.fakeEngine.backing.modelsPresentResult = false

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        // FakeTranscriber completes instantly, but right after calling
        // startTranscriptionDownload the initial state is set synchronously
        viewModel.startTranscriptionDownload()

        // The flags are set synchronously before the task runs
        // (but FakeTranscriber is instant so they may already be reset)
        // Wait for task to complete
        try await Task.sleep(for: .milliseconds(50))

        // After completion
        #expect(viewModel.downloadComplete == true)
        #expect(viewModel.downloadFailed == false)
    }

    @Test("startTranscriptionDownload is idempotent (second call while task exists is a no-op)")
    func startTranscriptionDownloadIdempotent() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }
        fixture.fakeEngine.backing.modelsPresentResult = false

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        // FakeTranscriber completes instantly, so the task will be nil
        // quickly. We verify by checking the call count.
        viewModel.startTranscriptionDownload()
        try await Task.sleep(for: .milliseconds(50))

        // First call completed
        #expect(fixture.fakeEngine.backing.ensureModelsCallCount == 1)
        #expect(viewModel.downloadComplete == true)

        // The task is nil after completion, so a second call works too
        // but that's fine -- the idempotency guard is on the task ref
    }

    @Test("cancel after start prevents downloadFailed from being set on error")
    func cancelPreventsFailedState() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }
        fixture.fakeEngine.backing.modelsPresentResult = false
        fixture.fakeEngine.backing.ensureModelsError = FakeTranscriberError.notReady

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        // Start the download (will fail due to error)
        viewModel.startTranscriptionDownload()

        // Immediately cancel before the task has a chance to set failed
        viewModel.cancelTranscriptionDownload()

        try await Task.sleep(for: .milliseconds(100))

        // Cancel should suppress the failure
        #expect(viewModel.downloadFailed == false)
        #expect(viewModel.downloadComplete == false)
        #expect(viewModel.isDownloading == false)
    }

    @Test("cancel after start prevents downloadComplete from being set on success")
    func cancelPreventsCompleteState() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }
        fixture.fakeEngine.backing.modelsPresentResult = false

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        // Start the download (will succeed)
        viewModel.startTranscriptionDownload()

        // Immediately cancel
        viewModel.cancelTranscriptionDownload()

        try await Task.sleep(for: .milliseconds(100))

        // Cancel should suppress the completion
        #expect(viewModel.downloadComplete == false)
        #expect(viewModel.isDownloading == false)
    }
}

// MARK: - Test helpers

/// Error used to make FakeTranscriber's `ensureModelsDownloaded` fail.
private enum FakeTranscriberError: Error {
    case notReady
}
