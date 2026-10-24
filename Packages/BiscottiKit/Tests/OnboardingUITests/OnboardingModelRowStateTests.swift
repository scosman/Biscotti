import BiscottiTestSupport
import DataStore
import Intelligence
import LocalLLM
import Testing
import TranscriptionService
@testable import OnboardingUI

// MARK: - Transcription row-state mapping

@Suite("OnboardingViewModel -- Transcription row state")
@MainActor
struct TranscriptionRowStateTests {
    @Test("idle with 626 MB caption when Whisper target, not downloaded")
    func whisperIdle() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }
        // Target is Whisper (default on macOS 15); Whisper not present

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance() // welcome -> permissions
        await viewModel.skip() // -> modelDownload

        #expect(viewModel.transcriptionRowState() == .idle(sizeCaption: "626 MB"))
    }

    @Test("idle with System download caption when Apple target, not ready")
    func appleIdle() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            appleAvailability: .available,
            appleLocales: ["en_US"],
            appleEquivalent: "en_US",
            appleInstalled: [] // not installed
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.transcriptionRowState() == .idle(sizeCaption: "System download"))
    }

    @Test("ready with Built in caption when Apple target, ready")
    func appleReady() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            appleAvailability: .available,
            appleLocales: ["en_US"],
            appleEquivalent: "en_US",
            appleInstalled: ["en_US"]
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.transcriptionRowState() == .ready(caption: "Built in"))
    }

    @Test("ready with no caption when Whisper target, ready")
    func whisperReady() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            whisperPresent: true,
            speakerIDPresent: true
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.transcriptionRowState() == .ready(caption: nil))
    }

    @Test("insufficientDisk when Whisper target and disk is low")
    func whisperInsufficientDisk() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            hardwareDiskBytes: 1_048_576 // 1 MB
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.transcriptionRowState() == .insufficientDisk)
    }

    @Test("failed when engine download failed")
    func whisperFailed() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        // Simulate a failed Whisper download via SpeechEngineManager
        fixture.speechEngines.whisper = .failed(message: "Network error")

        #expect(viewModel.transcriptionRowState() == .failed(message: "Network error"))
    }

    @Test("downloading indeterminate when Whisper target is downloading")
    func whisperDownloading() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        // Whisper downloads map to indeterminate progress
        fixture.speechEngines.whisper = .downloading(fraction: nil)

        #expect(
            viewModel.transcriptionRowState()
                == .downloading(.indeterminate(status: "Downloading\u{2026}"))
        )
    }

    @Test("downloading determinate when Apple target is downloading")
    func appleDownloading() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            appleAvailability: .available,
            appleLocales: ["en_US"],
            appleEquivalent: "en_US",
            appleInstalled: [] // not installed
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        // Apple downloads map to determinate progress
        fixture.speechEngines.apple = .downloading(fraction: 0.65)

        #expect(
            viewModel.transcriptionRowState()
                == .downloading(.determinate(fraction: 0.65))
        )
    }

    @Test("checking when isPreparingModelStep and model not ready")
    func checkingWhilePreparing() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        viewModel.isPreparingModelStep = true
        #expect(viewModel.transcriptionRowState() == .checking)
    }

    @Test("ready trumps checking when engine target is ready")
    func readyTrumpsChecking() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            whisperPresent: true,
            speakerIDPresent: true
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        viewModel.isPreparingModelStep = true
        #expect(viewModel.transcriptionReady == true)
        #expect(viewModel.transcriptionRowState() == .ready(caption: nil))
    }
}

// MARK: - Speaker ID row-state mapping

@Suite("OnboardingViewModel -- Speaker ID row state")
@MainActor
struct SpeakerIDRowStateTests {
    @Test("idle with ~11 MB caption when not downloaded")
    func speakerIDIdle() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.speakerIDRowState() == .idle(sizeCaption: "~11 MB"))
    }

    @Test("ready when Speaker ID is downloaded")
    func speakerIDReady() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            speakerIDPresent: true
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.speakerIDRowState() == .ready())
    }

    @Test("downloading indeterminate when in progress")
    func speakerIDDownloading() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        fixture.speechEngines.speakerID = .downloading(fraction: nil)

        #expect(
            viewModel.speakerIDRowState()
                == .downloading(.indeterminate(status: "Downloading\u{2026}"))
        )
    }

    @Test("failed when Speaker ID download failed")
    func speakerIDFailed() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        fixture.speechEngines.speakerID = .failed(message: "Install error")

        #expect(viewModel.speakerIDRowState() == .failed(message: "Install error"))
    }

    @Test("checking while preparing model step")
    func speakerIDChecking() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        viewModel.isPreparingModelStep = true
        #expect(viewModel.speakerIDRowState() == .checking)
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

        #expect(viewModel.languageRowState() == .ready())
    }

    @Test("downloading shows determinate progress")
    func languageDownloading() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

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
        #expect(viewModel.languageRowState() == .ready())
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

    @Test("target display name is non-nil and non-empty")
    func targetDisplayName() throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        let name = try #require(viewModel.languageTargetDisplayName)
        #expect(!name.isEmpty)
    }

    @Test("low-RAM Mac targets E2B (not 12B)")
    func lowRAMTargetsE2B() throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            hardwareRAMBytes: 12_000_000_000
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        #expect(viewModel.languageTargetModelID == "gemma-4-e2b")
    }

    @Test("in-flight non-recommended download becomes the target")
    func inflightNonRecommendedBecomesTarget() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        let nonRecommendedID = "gemma-4-e2b"
        #expect(nonRecommendedID != fixture.modelManager.recommendedModelID())

        fixture.modelManager.downloads[nonRecommendedID] = .downloading(fraction: 0.35)

        #expect(viewModel.languageTargetModelID == nonRecommendedID)
        #expect(viewModel.languageTargetDisplayName == LLMModelCatalog.model(id: nonRecommendedID)?.displayName)
        #expect(viewModel.languageRowState() == .downloading(.determinate(fraction: 0.35)))
        #expect(viewModel.languageStarted == true)
    }

    @Test("selected model (via DataStore) drives target when no download or active model")
    func selectedModelDrivesTarget() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let nonRecommendedID = "gemma-4-e2b"
        try await fixture.store.updateSettings { $0.selectedModelID = nonRecommendedID }
        await fixture.modelManager.refresh()

        #expect(fixture.modelManager.activeModelID == nil)
        #expect(fixture.modelManager.selectedModelID == nonRecommendedID)

        let viewModel = OnboardingViewModel(core: fixture.core)
        #expect(viewModel.languageTargetModelID == nonRecommendedID)
    }

    @Test("downloading wins over a stale failed entry")
    func downloadingWinsOverFailed() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        fixture.modelManager.downloads["gemma-4-12b"] = .failed(message: "Stale error")
        fixture.modelManager.downloads["gemma-4-e2b"] = .downloading(fraction: 0.6)

        #expect(viewModel.languageTargetModelID == "gemma-4-e2b")
        #expect(viewModel.languageRowState() == .downloading(.determinate(fraction: 0.6)))
        #expect(viewModel.languageStarted == true)
    }

    @Test("failed does not shadow an active model")
    func failedDoesNotShadowActive() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            modelDownloaded: true
        )
        defer { fixture.cleanup() }
        await fixture.modelManager.refresh()

        let activeID = fixture.modelManager.activeModelID
        #expect(activeID != nil)

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        let otherID = "gemma-4-e2b"
        #expect(otherID != activeID)
        fixture.modelManager.downloads[otherID] = .failed(message: "Network error")

        #expect(viewModel.languageTargetModelID == activeID)
        #expect(viewModel.languageRowState() == .ready())
    }

    @Test("failed target does not count as languageStarted")
    func failedTargetNotStarted() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        let failedID = "gemma-4-e2b"
        fixture.modelManager.downloads[failedID] = .failed(message: "Oops")

        #expect(viewModel.languageTargetModelID == failedID)
        #expect(viewModel.languageStarted == false)
        #expect(viewModel.allModelsStarted == false)
    }
}

// MARK: - Footer matrix (all three models)

@Suite("OnboardingViewModel -- Footer matrix (all three models)")
@MainActor
struct FooterMatrixTests {
    @Test("none ready nor downloading shows skip")
    func noneReadyShowsSkip() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.transcriptionReady == false)
        #expect(viewModel.speakerIDReady == false)
        #expect(viewModel.languageReady == false)
        #expect(viewModel.allModelsReady == false)
        #expect(viewModel.allModelsStarted == false)
        #expect(viewModel.footerButton(for: .modelDownload) == .skip)
    }

    @Test("only transcription ready shows skip (speaker ID and language not started)")
    func onlyTranscriptionReadyShowsSkip() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            whisperPresent: true
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.transcriptionReady == true)
        #expect(viewModel.speakerIDReady == false)
        #expect(viewModel.languageReady == false)
        #expect(viewModel.allModelsStarted == false)
        #expect(viewModel.footerButton(for: .modelDownload) == .skip)
    }

    @Test("all three ready shows continue")
    func allReadyShowsContinue() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            modelDownloaded: true,
            whisperPresent: true,
            speakerIDPresent: true
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.transcriptionReady == true)
        #expect(viewModel.speakerIDReady == true)
        #expect(viewModel.languageReady == true)
        #expect(viewModel.allModelsReady == true)
        #expect(viewModel.allModelsStarted == true)
        #expect(viewModel.footerButton(for: .modelDownload) == .continueButton)
    }

    @Test("all three downloading shows continue")
    func allDownloadingShowsContinue() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        // Simulate all downloading
        fixture.speechEngines.whisper = .downloading(fraction: nil)
        fixture.speechEngines.speakerID = .downloading(fraction: nil)
        guard let targetID = viewModel.languageTargetModelID else {
            Issue.record("No language target model ID")
            return
        }
        fixture.modelManager.downloads[targetID] = .downloading(fraction: 0.3)

        #expect(viewModel.transcriptionStarted == true)
        #expect(viewModel.speakerIDStarted == true)
        #expect(viewModel.languageStarted == true)
        #expect(viewModel.allModelsStarted == true)
        #expect(viewModel.allModelsReady == false)
        #expect(viewModel.footerButton(for: .modelDownload) == .continueButton)
    }

    @Test("two ready + one downloading shows continue")
    func twoReadyOneDownloadingShowsContinue() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            whisperPresent: true,
            speakerIDPresent: true
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        // Language downloading
        guard let targetID = viewModel.languageTargetModelID else {
            Issue.record("No language target model ID")
            return
        }
        fixture.modelManager.downloads[targetID] = .downloading(fraction: 0.5)

        #expect(viewModel.transcriptionReady == true)
        #expect(viewModel.speakerIDReady == true)
        #expect(viewModel.languageStarted == true)
        #expect(viewModel.allModelsStarted == true)
        #expect(viewModel.footerButton(for: .modelDownload) == .continueButton)
    }

    @Test("transcription + language ready but speaker ID not started shows skip")
    func missingOnlySpkIDShowsSkip() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            modelDownloaded: true,
            whisperPresent: true
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.transcriptionReady == true)
        #expect(viewModel.speakerIDReady == false)
        #expect(viewModel.languageReady == true)
        #expect(viewModel.allModelsStarted == false)
        #expect(viewModel.footerButton(for: .modelDownload) == .skip)
    }
}

// MARK: - allModelsStarted derivation

@Suite("OnboardingViewModel -- allModelsStarted")
@MainActor
struct AllModelsStartedTests {
    @Test("none started is false")
    func noneStarted() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.transcriptionStarted == false)
        #expect(viewModel.speakerIDStarted == false)
        #expect(viewModel.languageStarted == false)
        #expect(viewModel.allModelsStarted == false)
    }

    @Test("only transcription started is false")
    func onlyTranscriptionStarted() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            whisperPresent: true
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.transcriptionStarted == true)
        #expect(viewModel.speakerIDStarted == false)
        #expect(viewModel.languageStarted == false)
        #expect(viewModel.allModelsStarted == false)
    }

    @Test("only language started is false")
    func onlyLanguageStarted() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        guard let targetID = viewModel.languageTargetModelID else {
            Issue.record("No language target model ID")
            return
        }
        fixture.modelManager.downloads[targetID] = .downloading(fraction: 0.1)

        #expect(viewModel.transcriptionStarted == false)
        #expect(viewModel.speakerIDStarted == false)
        #expect(viewModel.languageStarted == true)
        #expect(viewModel.allModelsStarted == false)
    }

    @Test("all three downloading is true")
    func allDownloading() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        fixture.speechEngines.whisper = .downloading(fraction: nil)
        fixture.speechEngines.speakerID = .downloading(fraction: nil)
        guard let targetID = viewModel.languageTargetModelID else {
            Issue.record("No language target model ID")
            return
        }
        fixture.modelManager.downloads[targetID] = .downloading(fraction: 0.5)

        #expect(viewModel.allModelsStarted == true)
    }

    @Test("all three ready is true")
    func allReady() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            modelDownloaded: true,
            whisperPresent: true,
            speakerIDPresent: true
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.allModelsReady == true)
        #expect(viewModel.allModelsStarted == true)
    }

    @Test("two ready + one downloading is true")
    func twoReadyOneDownloading() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            whisperPresent: true,
            speakerIDPresent: true
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        guard let targetID = viewModel.languageTargetModelID else {
            Issue.record("No language target model ID")
            return
        }
        fixture.modelManager.downloads[targetID] = .downloading(fraction: 0.7)

        #expect(viewModel.transcriptionReady == true)
        #expect(viewModel.speakerIDReady == true)
        #expect(viewModel.languageStarted == true)
        #expect(viewModel.allModelsStarted == true)
    }
}

// MARK: - On-entry preparation

@Suite("OnboardingViewModel -- Model step preparation")
@MainActor
struct ModelStepPreparationTests {
    @Test("prepareModelStep refreshes SpeechEngineManager and ModelManager")
    func prepareRefreshesEngines() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            modelDownloaded: true,
            whisperPresent: true,
            speakerIDPresent: true
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance() // welcome -> permissions
        await viewModel.skip() // -> modelDownload (prepareModelStep runs)

        // After refresh, models should be ready
        #expect(viewModel.transcriptionReady == true)
        #expect(viewModel.languageReady == true)
    }

    @Test("isPreparingModelStep is false after skip completes")
    func preparingFalseAfterSkip() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

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
        await viewModel.advance() // -> modelDownload

        #expect(viewModel.isPreparingModelStep == false)
        #expect(viewModel.currentStep == .modelDownload)
    }

    @Test("beginModelPrep is idempotent -- second call on model-download is a no-op")
    func beginModelPrepIdempotent() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance() // welcome -> permissions (pre-warm fires)
        await viewModel.skip() // -> modelDownload (beginModelPrep called again, but guard returns)

        // modelsPresent is called twice per refresh (whisper + speakerID)
        // but only one beginModelPrep task runs (the guard prevents re-fire).
        #expect(fixture.managerEngine.backing.modelsPresentCallCount == 2)
    }

    @Test("resetForReplay clears modelPrepTask and isPreparingModelStep")
    func resetForReplayClearsPrepTask() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.isPreparingModelStep == false)

        viewModel.resetForReplay()

        #expect(viewModel.currentStep == .welcome)
        #expect(viewModel.isPreparingModelStep == false)

        // A new advance re-fires the pre-warm (task was nilled out)
        await viewModel.advance()
        await viewModel.skip()

        // modelsPresent called 4 times total: 2 per refresh (whisper + speakerID),
        // one refresh before reset and one after.
        #expect(fixture.managerEngine.backing.modelsPresentCallCount == 4)
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

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance() // welcome -> permissions
        await viewModel.skip() // -> modelDownload

        #expect(viewModel.allModelsReady == false)
        await viewModel.skip() // -> done
        #expect(viewModel.currentStep == .done)
    }

    @Test("advance advances to done when all ready")
    func advanceAdvancesToDone() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            modelDownloaded: true,
            whisperPresent: true,
            speakerIDPresent: true
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.allModelsReady == true)
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

// MARK: - Footer caption

@Suite("OnboardingViewModel -- Footer caption")
@MainActor
struct FooterCaptionTests {
    @Test("caption shows when all models downloading (Continue visible, downloads active)")
    func captionShowsWhenAllDownloading() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance() // welcome -> permissions
        await viewModel.skip() // -> modelDownload

        // Simulate all downloading
        fixture.speechEngines.whisper = .downloading(fraction: nil)
        fixture.speechEngines.speakerID = .downloading(fraction: nil)
        guard let targetID = viewModel.languageTargetModelID else {
            Issue.record("No language target model ID")
            return
        }
        fixture.modelManager.downloads[targetID] = .downloading(fraction: 0.3)

        #expect(viewModel.allModelsStarted == true)
        #expect(viewModel.allModelsReady == false)
        #expect(viewModel.footerCaption == "Downloads will continue in the background")
    }

    @Test("caption shows when some ready and rest downloading")
    func captionShowsWhenSomeReadySomeDownloading() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            whisperPresent: true
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        // Transcription ready; speaker ID and language downloading
        fixture.speechEngines.speakerID = .downloading(fraction: nil)
        guard let targetID = viewModel.languageTargetModelID else {
            Issue.record("No language target model ID")
            return
        }
        fixture.modelManager.downloads[targetID] = .downloading(fraction: 0.5)

        #expect(viewModel.transcriptionReady == true)
        #expect(viewModel.speakerIDStarted == true)
        #expect(viewModel.languageStarted == true)
        #expect(viewModel.allModelsStarted == true)
        #expect(viewModel.allModelsReady == false)
        #expect(viewModel.footerCaption == "Downloads will continue in the background")
    }

    @Test("caption blank when all models ready")
    func captionBlankWhenAllReady() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            modelDownloaded: true,
            whisperPresent: true,
            speakerIDPresent: true
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.allModelsReady == true)
        #expect(viewModel.footerCaption == "")
    }

    @Test("caption blank when no model started (Skip showing)")
    func captionBlankWhenNoneStarted() async throws {
        let fixture = try makeCoreFixture(calendarAuthStatus: .denied)
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        #expect(viewModel.allModelsStarted == false)
        #expect(viewModel.footerCaption == "")
    }

    @Test("caption blank on non-model steps")
    func captionBlankOnNonModelSteps() throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)

        #expect(viewModel.currentStep == .welcome)
        #expect(viewModel.footerCaption == "")
    }

    @Test("caption blank on permissions step")
    func captionBlankOnPermissionsStep() async throws {
        let fixture = try makeCoreFixture(
            micStatus: .notDetermined,
            calendarAuthStatus: .notDetermined
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance() // welcome -> permissions

        #expect(viewModel.currentStep == .permissions)
        #expect(viewModel.footerCaption == "")
    }
}
