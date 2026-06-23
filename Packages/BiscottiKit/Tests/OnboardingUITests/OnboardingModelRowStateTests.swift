import BiscottiTestSupport
import DataStore
import Intelligence
import LocalLLM
import Testing
@testable import OnboardingUI

// MARK: - Transcription row-state mapping

@Suite("OnboardingViewModel -- Transcription row state")
@MainActor
struct TranscriptionRowStateTests {
    @Test("idle when not downloaded, sufficient disk")
    func transcriptionIdle() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }
        // Prevent FakeTranscriber from reporting models as ready
        fixture.fakeEngine.backing.ensureModelsError = FakeTranscriberError.notReady

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance() // welcome -> permissions
        await viewModel.skip() // -> modelDownload (prepareModelStep runs)

        let state = viewModel.transcriptionRowState()
        #expect(state == .idle(sizeCaption: "~1.5 GB"))
    }

    @Test("ready when transcription already downloaded on entry")
    func transcriptionReadyOnEntry() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }
        // FakeTranscriber succeeds on modelsReady by default

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance() // welcome -> permissions
        await viewModel.skip() // -> modelDownload

        #expect(viewModel.transcriptionDownloaded == true)
        #expect(viewModel.transcriptionRowState() == .ready)
    }

    @Test("ready after explicit transcription download completes")
    func transcriptionReadyAfterDownload() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }
        fixture.fakeEngine.backing.ensureModelsError = FakeTranscriberError.notReady

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.transcriptionRowState() == .idle(sizeCaption: "~1.5 GB"))

        // Clear the error so download succeeds
        fixture.fakeEngine.backing.ensureModelsError = nil
        await viewModel.startTranscriptionDownload()

        #expect(viewModel.downloadComplete == true)
        #expect(viewModel.transcriptionRowState() == .ready)
    }

    @Test("insufficientDisk when disk is low")
    func transcriptionInsufficientDisk() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }
        fixture.fakeEngine.backing.ensureModelsError = FakeTranscriberError.notReady

        let viewModel = OnboardingViewModel(
            core: fixture.core,
            availableDiskBytes: { 1_048_576 } // 1 MB -- well below threshold
        )
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.transcriptionRowState() == .insufficientDisk)
    }

    // Note: transcription downloading state (.indeterminate) can't be
    // captured in a unit test because FakeTranscriber completes immediately.
    // The mapper code path is covered by reading the switch in
    // transcriptionRowState(); the language row's downloading path exercises
    // the equivalent pattern with direct ModelManager state injection.

    @Test("failed when download fails")
    func transcriptionFailed() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }
        fixture.fakeEngine.backing.ensureModelsError = FakeTranscriberError.notReady

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        // Attempt download with the error set
        await viewModel.startTranscriptionDownload()

        // The error message contains "failed"
        #expect(viewModel.transcriptionRowState() == .failed(message: "Download failed. You can retry or skip."))
    }
}

// MARK: - Transcription row-state checking

@Suite("OnboardingViewModel -- Transcription row checking state")
@MainActor
struct TranscriptionRowCheckingTests {
    @Test("checking when isPreparingModelStep and model not ready")
    func checkingWhilePreparing() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }
        fixture.fakeEngine.backing.ensureModelsError = FakeTranscriberError.notReady

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance() // welcome -> permissions
        await viewModel.skip() // -> modelDownload (prepareModelStep completes)

        // Simulate the preparing flag being set (as if mid-preparation)
        viewModel.isPreparingModelStep = true
        #expect(viewModel.transcriptionRowState() == .checking)
    }

    @Test("ready trumps checking when model already downloaded")
    func readyTrumpsChecking() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }
        // FakeTranscriber succeeds on modelsReady by default

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        // Model is ready AND we simulate mid-preparation
        viewModel.isPreparingModelStep = true
        #expect(viewModel.transcriptionReady == true)
        #expect(viewModel.transcriptionRowState() == .ready)
    }
}

// MARK: - Language row-state mapping

@Suite("OnboardingViewModel -- Language row state")
@MainActor
struct LanguageRowStateTests {
    @Test("idle with size caption when no model downloaded")
    func languageIdle() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        let state = viewModel.languageRowState()
        // Target should be the recommended model; size depends on catalog
        if case let .idle(sizeCaption) = state {
            #expect(!sizeCaption.isEmpty)
        } else {
            Issue.record("Expected .idle state, got \(state)")
        }
    }

    @Test("ready when language model is downloaded")
    func languageReady() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            modelDownloaded: true
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.languageRowState() == .ready)
    }

    @Test("downloading shows determinate progress")
    func languageDownloading() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        // Simulate an in-flight download for the target model
        guard let targetID = viewModel.languageTargetModelID else {
            Issue.record("No language target model ID")
            return
        }
        fixture.modelManager.downloads[targetID] = .downloading(fraction: 0.42)

        #expect(viewModel.languageRowState() == .downloading(.determinate(fraction: 0.42)))
    }

    @Test("downloading with nil fraction shows determinate nil")
    func languageDownloadingNilFraction() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        guard let targetID = viewModel.languageTargetModelID else {
            Issue.record("No language target model ID")
            return
        }
        fixture.modelManager.downloads[targetID] = .downloading(fraction: nil)

        #expect(viewModel.languageRowState() == .downloading(.determinate(fraction: nil)))
    }

    @Test("failed when download fails")
    func languageFailed() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        guard let targetID = viewModel.languageTargetModelID else {
            Issue.record("No language target model ID")
            return
        }
        fixture.modelManager.downloads[targetID] = .failed(message: "Network error")

        #expect(viewModel.languageRowState() == .failed(message: "Network error"))
    }

    @Test("insufficientDisk when target model blocked by disk")
    func languageInsufficientDisk() async throws {
        // Report only 1 byte of free disk so ModelSuitability blocks all models
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            hardwareDiskBytes: 1
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.languageRowState() == .insufficientDisk)
    }
}

// MARK: - Language row-state checking

@Suite("OnboardingViewModel -- Language row checking state")
@MainActor
struct LanguageRowCheckingTests {
    @Test("checking when isPreparingModelStep and model not ready")
    func checkingWhilePreparing() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        // Simulate mid-preparation
        viewModel.isPreparingModelStep = true
        #expect(viewModel.languageRowState() == .checking)
    }

    @Test("ready trumps checking when language model downloaded")
    func readyTrumpsChecking() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            modelDownloaded: true
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        viewModel.isPreparingModelStep = true
        #expect(viewModel.languageReady == true)
        #expect(viewModel.languageRowState() == .ready)
    }

    @Test("downloading trumps checking during in-flight download")
    func downloadingTrumpsChecking() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        guard let targetID = viewModel.languageTargetModelID else {
            Issue.record("No language target model ID")
            return
        }

        // Simulate in-flight download AND mid-preparation
        fixture.modelManager.downloads[targetID] = .downloading(fraction: 0.5)
        viewModel.isPreparingModelStep = true

        #expect(viewModel.languageRowState() == .downloading(.determinate(fraction: 0.5)))
    }
}

// MARK: - Target model

@Suite("OnboardingViewModel -- Language target model")
@MainActor
struct LanguageTargetModelTests {
    @Test("target is recommended model when nothing downloaded")
    func targetIsRecommended() throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        let recommended = fixture.modelManager.recommendedModelID()
        #expect(viewModel.languageTargetModelID == recommended)
        #expect(recommended != nil)
    }

    @Test("target is active model when one is downloaded")
    func targetIsActive() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            modelDownloaded: true
        )
        defer { fixture.cleanup() }
        await fixture.modelManager.refresh()

        let viewModel = OnboardingViewModel(core: fixture.core)
        let active = fixture.modelManager.activeModelID
        #expect(active != nil)
        #expect(viewModel.languageTargetModelID == active)
    }

    @Test("recommended display name is non-nil and non-empty")
    func recommendedDisplayName() throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        let name = try #require(viewModel.recommendedLanguageDisplayName)
        #expect(!name.isEmpty)
    }

    @Test("low-RAM Mac targets E2B (not 12B)")
    func lowRAMTargetsE2B() throws {
        // 12GB RAM: below the 15GB floor for 12B
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            hardwareRAMBytes: 12_000_000_000
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        #expect(viewModel.languageTargetModelID == "gemma-4-e2b")
    }
}

// MARK: - Footer matrix (both models)

@Suite("OnboardingViewModel -- Footer matrix (both models)")
@MainActor
struct FooterMatrixTests {
    @Test("neither ready shows skip")
    func neitherReadyShowsSkip() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }
        fixture.fakeEngine.backing.ensureModelsError = FakeTranscriberError.notReady

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.transcriptionReady == false)
        #expect(viewModel.languageReady == false)
        #expect(viewModel.bothModelsReady == false)
        #expect(viewModel.footerButton(for: .modelDownload) == .skip)
    }

    @Test("only transcription ready shows skip")
    func onlyTranscriptionReadyShowsSkip() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }
        // FakeTranscriber succeeds -> transcription ready; no language model

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.transcriptionReady == true)
        #expect(viewModel.languageReady == false)
        #expect(viewModel.footerButton(for: .modelDownload) == .skip)
    }

    @Test("only language ready shows skip")
    func onlyLanguageReadyShowsSkip() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            modelDownloaded: true
        )
        defer { fixture.cleanup() }
        fixture.fakeEngine.backing.ensureModelsError = FakeTranscriberError.notReady

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.transcriptionReady == false)
        #expect(viewModel.languageReady == true)
        #expect(viewModel.footerButton(for: .modelDownload) == .skip)
    }

    @Test("both ready shows continue")
    func bothReadyShowsContinue() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            modelDownloaded: true
        )
        defer { fixture.cleanup() }
        // FakeTranscriber succeeds -> transcription ready; model pre-downloaded

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.transcriptionReady == true)
        #expect(viewModel.languageReady == true)
        #expect(viewModel.bothModelsReady == true)
        #expect(viewModel.footerButton(for: .modelDownload) == .continueButton)
    }
}

// MARK: - On-entry preparation

@Suite("OnboardingViewModel -- Model step preparation")
@MainActor
struct ModelStepPreparationTests {
    @Test("prepareModelStep sets transcriptionDownloaded from probe")
    func prepareSetsTxDownloaded() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        #expect(viewModel.transcriptionDownloaded == false)

        await viewModel.advance() // welcome -> permissions
        await viewModel.skip() // -> modelDownload (prepareModelStep runs)

        // FakeTranscriber reports ready by default
        #expect(viewModel.transcriptionDownloaded == true)
    }

    @Test("prepareModelStep sets transcriptionDownloaded false when not ready")
    func prepareSetsTxNotDownloaded() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }
        fixture.fakeEngine.backing.ensureModelsError = FakeTranscriberError.notReady

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.transcriptionDownloaded == false)
    }

    @Test("prepareModelStep refreshes ModelManager so downloaded model shows ready")
    func prepareRefreshesModelManager() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            modelDownloaded: true
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        // After refresh, the language model should be ready
        #expect(viewModel.languageReady == true)
    }

    @Test("isPreparingModelStep is false after skip completes")
    func preparingFalseAfterSkip() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance() // welcome -> permissions
        await viewModel.skip() // -> modelDownload (prepareModelStep runs and finishes)

        #expect(viewModel.isPreparingModelStep == false)
    }

    @Test("isPreparingModelStep is false after advance completes")
    func preparingFalseAfterAdvance() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .authorized,
            modelDownloaded: true
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance() // welcome -> permissions
        await viewModel.requestCalendar()
        await viewModel.advance() // -> calendarSelection
        await viewModel.advance() // -> modelDownload (prepareModelStep runs)

        #expect(viewModel.isPreparingModelStep == false)
        #expect(viewModel.currentStep == .modelDownload)
    }

    @Test("prepareModelStep runs from calendarSelection path too")
    func prepareRunsFromCalendarPath() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .authorized,
            modelDownloaded: true
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance() // welcome -> permissions
        await viewModel.requestCalendar()
        await viewModel.advance() // -> calendarSelection
        await viewModel.advance() // -> modelDownload (prepareModelStep runs)

        #expect(viewModel.currentStep == .modelDownload)
        #expect(viewModel.transcriptionDownloaded == true)
        #expect(viewModel.languageReady == true)
    }
}

// MARK: - Skip/advance from model download

@Suite("OnboardingViewModel -- Skip/advance from model download")
@MainActor
struct ModelDownloadNavigationTests {
    @Test("skip advances to done regardless of readiness")
    func skipAdvancesToDone() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }
        fixture.fakeEngine.backing.ensureModelsError = FakeTranscriberError.notReady

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance() // welcome -> permissions
        await viewModel.skip() // -> modelDownload

        #expect(viewModel.bothModelsReady == false)
        await viewModel.skip() // -> done
        #expect(viewModel.currentStep == .done)
    }

    @Test("advance advances to done when both ready")
    func advanceAdvancesToDone() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            modelDownloaded: true
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.bothModelsReady == true)
        await viewModel.advance()
        #expect(viewModel.currentStep == .done)
    }
}

// MARK: - Format bytes helper

@Suite("OnboardingViewModel -- formatBytes")
@MainActor
struct FormatBytesTests {
    @Test("formats whole gigabytes without decimal")
    func wholeGB() {
        #expect(OnboardingViewModel.formatBytes(3_000_000_000) == "~3 GB")
        #expect(OnboardingViewModel.formatBytes(7_000_000_000) == "~7 GB")
    }

    @Test("formats fractional gigabytes with one decimal")
    func fractionalGB() {
        #expect(OnboardingViewModel.formatBytes(3_200_000_000) == "~3.2 GB")
        #expect(OnboardingViewModel.formatBytes(1_500_000_000) == "~1.5 GB")
    }
}

// MARK: - Test helpers

/// Error used to make FakeTranscriber's `ensureModelsDownloaded` fail,
/// simulating models not being cached on disk.
private enum FakeTranscriberError: Error {
    case notReady
}
