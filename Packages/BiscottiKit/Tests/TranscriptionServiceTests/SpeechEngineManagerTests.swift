import BiscottiTestSupport
import Foundation
import Testing
import Transcription
import TranscriptionService
@testable import DataStore

// MARK: - Helper

@MainActor
private struct ManagerFixture {
    let manager: SpeechEngineManager
    let engine: FakeTranscriber
    let apple: FakeAppleSpeech
    let store: DataStore
}

@MainActor
private func makeManager(
    appleAvailability: AppleSpeechAvailability = .available,
    locales: [String] = ["en_US", "en_GB", "fr_FR"],
    equivalent: String? = "en_US",
    installed: Set<String> = ["en_US"],
    whisperPresent: Bool = false,
    speakerIDPresent: Bool = false,
    diskBytes: Int64? = 100_000_000_000,
    isJobInFlight: @escaping @MainActor () -> Bool = { false }
) throws -> ManagerFixture {
    let store = try DataStore(storage: .inMemory)
    let engine = FakeTranscriber()
    engine.backing.componentPresent[.whisper] = whisperPresent
    engine.backing.componentPresent[.speakerID] = speakerIDPresent
    let apple = FakeAppleSpeech(
        availability: appleAvailability,
        locales: locales,
        equivalent: equivalent,
        installed: installed
    )
    let manager = SpeechEngineManager(
        store: store,
        transcriber: engine,
        apple: apple,
        diskProbe: { diskBytes },
        isJobInFlight: isJobInFlight
    )
    return ManagerFixture(manager: manager, engine: engine, apple: apple, store: store)
}

// MARK: - Refresh

@Suite("SpeechEngineManager -- refresh")
@MainActor
struct SpeechEngineManagerRefreshTests {
    @Test("refresh populates all state from available Apple + Whisper present")
    func refreshPopulatesAllState() async throws {
        let fix = try makeManager(
            whisperPresent: true,
            speakerIDPresent: true
        )

        await fix.manager.refresh()

        if case .available = fix.manager.appleAvailability {} else {
            Issue.record("Expected .available, got \(fix.manager.appleAvailability)")
        }
        #expect(fix.manager.appleLocale == "en_US")
        #expect(fix.manager.apple == .downloaded)
        #expect(fix.manager.whisper == .downloaded)
        #expect(fix.manager.speakerID == .downloaded)
        #expect(fix.manager.languageSupported == true)
        #expect(fix.manager.recommended == .apple)
        // No explicit selection -> follows recommended
        #expect(fix.manager.selection == nil)
        #expect(fix.manager.target == .apple)
        #expect(!fix.manager.appleLocales.isEmpty)
    }

    @Test("refresh with requiresOSUpdate clears Apple state")
    func refreshRequiresOSUpdate() async throws {
        let fix = try makeManager(
            appleAvailability: .requiresOSUpdate(currentMajor: 15),
            locales: []
        )

        await fix.manager.refresh()

        #expect(fix.manager.appleLocales.isEmpty)
        #expect(fix.manager.languageSupported == false)
        #expect(fix.manager.recommended == .whisper)
        #expect(fix.manager.target == .whisper)
        #expect(fix.manager.apple == .notDownloaded)
    }

    @Test("refresh keeps in-flight download states untouched")
    func refreshKeepsInFlightDownloads() async throws {
        let fix = try makeManager(whisperPresent: true)

        fix.manager.whisper = .downloading(fraction: 0.5)
        await fix.manager.refresh()

        #expect(fix.manager.whisper == .downloading(fraction: 0.5))
    }

    @Test("refresh reads stored locale when valid")
    func refreshReadsStoredLocale() async throws {
        let fix = try makeManager(
            locales: ["en_US", "en_GB", "fr_FR"],
            installed: ["en_GB"]
        )

        try await fix.store.updateSettings { $0.appleSpeechLocale = "en_GB" }
        await fix.manager.refresh()

        #expect(fix.manager.appleLocale == "en_GB")
        #expect(fix.manager.apple == .downloaded)
    }

    @Test("migration pins whisper selection for existing users")
    func migrationPinsWhisperForExistingUser() async throws {
        let fix = try makeManager(
            whisperPresent: true
        )

        // Simulate existing user who completed onboarding but has no engine selection
        try await fix.store.updateSettings { $0.onboardingComplete = true }
        await fix.manager.refresh()

        #expect(fix.manager.selection == .whisper)
        let settings = try await fix.store.settings()
        #expect(settings.sttEngineSelection == "whisper")
    }

    @Test("migration does not fire for new users (onboarding incomplete)")
    func migrationSkipsNewUsers() async throws {
        let fix = try makeManager(
            whisperPresent: true
        )

        // onboardingComplete defaults to false
        await fix.manager.refresh()

        // No migration: selection stays nil (follows recommended)
        #expect(fix.manager.selection == nil)
    }
}

// MARK: - Selection

@Suite("SpeechEngineManager -- selection")
@MainActor
struct SpeechEngineManagerSelectionTests {
    @Test("choose requires isReady")
    func chooseRequiresReady() async throws {
        let fix = try makeManager()

        await fix.manager.refresh()
        // Apple is downloaded but whisper is not
        await fix.manager.choose(.whisper)

        // Selection should not have changed to whisper (not ready)
        #expect(fix.manager.selection != .whisper)
    }

    @Test("choose sets selection when ready and persists")
    func chooseSetsSelectionWhenReady() async throws {
        let fix = try makeManager()

        await fix.manager.refresh()
        // Apple is downloaded after refresh (en_US in installed set)
        #expect(fix.manager.isReady(.apple))
        await fix.manager.choose(.apple)

        #expect(fix.manager.selection == .apple)
        let settings = try await fix.store.settings()
        #expect(settings.sttEngineSelection == "apple")
    }

    @Test("target falls back from unavailable apple to whisper")
    func targetFallsBackFromUnavailableApple() async throws {
        let fix = try makeManager(
            appleAvailability: .requiresOSUpdate(currentMajor: 15),
            locales: [],
            whisperPresent: true
        )

        // Pre-set selection to apple in store
        try await fix.store.updateSettings { $0.sttEngineSelection = "apple" }
        await fix.manager.refresh()

        #expect(fix.manager.selection == .apple)
        // But target falls back because Apple is unavailable
        #expect(fix.manager.target == .whisper)
    }
}

// MARK: - Download

@Suite("SpeechEngineManager -- download")
@MainActor
struct SpeechEngineManagerDownloadTests {
    @Test("download whisper succeeds and sets selection")
    func downloadWhisperSucceeds() async throws {
        let fix = try makeManager()

        await fix.manager.refresh()
        await fix.manager.download(.whisper)

        #expect(fix.manager.whisper == .downloaded)
        #expect(fix.manager.selection == .whisper)
        #expect(fix.engine.backing.ensureModelsCalled == true)
        #expect(fix.engine.backing.shutdownCalled == true)

        let settings = try await fix.store.settings()
        #expect(settings.sttEngineSelection == "whisper")
    }

    @Test("download blocked when already in flight")
    func downloadBlockedWhenInFlight() async throws {
        let fix = try makeManager(
            installed: [] // Not installed so download would be needed
        )

        await fix.manager.refresh()
        // Simulate an in-flight whisper download
        fix.manager.whisper = .downloading(fraction: nil)
        #expect(fix.manager.isAnyDownloadInFlight == true)

        // Try to download apple while whisper is in flight
        await fix.manager.download(.apple)

        // Apple install should not have been called
        #expect(fix.apple.installCallCount == 0)
    }

    @Test("download blocked when not enough disk space")
    func downloadBlockedWhenLowDisk() async throws {
        let fix = try makeManager(
            diskBytes: 500 * 1_048_576 // 500 MB, less than 750 MB minimum
        )

        await fix.manager.refresh()
        #expect(fix.manager.hasEnoughDiskForWhisper == false)
        await fix.manager.download(.whisper)

        #expect(fix.manager.whisper == .notDownloaded)
    }

    @Test("download failure sets failed state")
    func downloadFailureSetsFailedState() async throws {
        let fix = try makeManager()

        await fix.manager.refresh()
        fix.engine.backing.ensureModelsError = NSError(
            domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Network timeout"]
        )
        await fix.manager.download(.whisper)

        if case let .failed(message) = fix.manager.whisper {
            #expect(message == "Network timeout")
        } else {
            Issue.record("Expected .failed, got \(fix.manager.whisper)")
        }
    }

    @Test("download apple calls installAssets on provider")
    func downloadAppleCallsInstallAssets() async throws {
        let fix = try makeManager(
            installed: [] // Not yet installed
        )

        await fix.manager.refresh()
        await fix.manager.download(.apple)

        #expect(fix.apple.installCallCount == 1)
        #expect(fix.manager.apple == .downloaded)
        #expect(fix.manager.selection == .apple)
    }
}

// MARK: - Delete

@Suite("SpeechEngineManager -- delete")
@MainActor
struct SpeechEngineManagerDeleteTests {
    @Test("delete whisper sets notDownloaded")
    func deleteWhisperWorks() async throws {
        let fix = try makeManager(whisperPresent: true)

        await fix.manager.refresh()
        #expect(fix.manager.whisper == .downloaded)

        await fix.manager.deleteWhisper()
        #expect(fix.manager.whisper == .notDownloaded)
    }

    @Test("delete blocked while job in flight")
    func deleteBlockedWhileJobInFlight() async throws {
        var jobInFlight = true
        let fix = try makeManager(
            whisperPresent: true,
            isJobInFlight: { jobInFlight }
        )

        await fix.manager.refresh()
        #expect(fix.manager.whisper == .downloaded)

        await fix.manager.deleteWhisper()
        #expect(fix.manager.whisper == .downloaded)

        // Now allow delete
        jobInFlight = false
        await fix.manager.deleteWhisper()
        #expect(fix.manager.whisper == .notDownloaded)
    }

    @Test("after deleting whisper with apple available, selection changes to apple")
    func deleteWhisperFallsBackToApple() async throws {
        let fix = try makeManager(
            whisperPresent: true
        )

        await fix.manager.refresh()
        // First select whisper explicitly
        await fix.manager.choose(.whisper)
        #expect(fix.manager.selection == .whisper)

        await fix.manager.deleteWhisper()

        #expect(fix.manager.whisper == .notDownloaded)
        #expect(fix.manager.selection == .apple)
        let settings = try await fix.store.settings()
        #expect(settings.sttEngineSelection == "apple")
    }
}

// MARK: - Locale

@Suite("SpeechEngineManager -- locale")
@MainActor
struct SpeechEngineManagerLocaleTests {
    @Test("setAppleLocale persists and re-checks assets")
    func setAppleLocalePersistsAndReChecks() async throws {
        let fix = try makeManager(
            installed: ["en_US"] // en_GB is NOT installed
        )

        await fix.manager.refresh()
        #expect(fix.manager.appleLocale == "en_US")
        #expect(fix.manager.apple == .downloaded)

        await fix.manager.setAppleLocale("en_GB")

        #expect(fix.manager.appleLocale == "en_GB")
        #expect(fix.manager.apple == .notDownloaded) // en_GB not installed
        let settings = try await fix.store.settings()
        #expect(settings.appleSpeechLocale == "en_GB")
    }

    @Test("setAppleLocale rejects unknown locale")
    func rejectsUnknownLocale() async throws {
        let fix = try makeManager()

        await fix.manager.refresh()
        let originalLocale = fix.manager.appleLocale

        await fix.manager.setAppleLocale("xx_ZZ")

        #expect(fix.manager.appleLocale == originalLocale)
    }
}

// MARK: - Derived

@Suite("SpeechEngineManager -- derived")
@MainActor
struct SpeechEngineManagerDerivedTests {
    @Test("effectiveCustomVocabulary true only when whisper target AND preference on")
    func effectiveCustomVocabulary() async throws {
        let fix = try makeManager(whisperPresent: true)

        await fix.manager.refresh()
        await fix.manager.choose(.whisper)

        // Whisper target + preference on -> true
        #expect(fix.manager.effectiveCustomVocabulary(storedPreference: true) == true)
        // Whisper target + preference off -> false
        #expect(fix.manager.effectiveCustomVocabulary(storedPreference: false) == false)

        // Switch to Apple target
        await fix.manager.choose(.apple)
        // Apple target + preference on -> false
        #expect(fix.manager.effectiveCustomVocabulary(storedPreference: true) == false)
    }

    @Test("jobConfig returns correct config per engine")
    func jobConfigPerEngine() async throws {
        let fix = try makeManager(whisperPresent: true)

        await fix.manager.refresh()

        // Default target is apple (recommended when available + supported)
        #expect(fix.manager.target == .apple)
        let appleConfig = fix.manager.jobConfig()
        #expect(appleConfig.engine == .apple)

        // Switch to whisper
        await fix.manager.choose(.whisper)
        let whisperConfig = fix.manager.jobConfig()
        #expect(whisperConfig.engine == .whisper)
    }

    @Test("jobComponents returns speakerID for apple, all for whisper")
    func jobComponentsPerEngine() async throws {
        let fix = try makeManager(whisperPresent: true)

        await fix.manager.refresh()

        // Apple target
        #expect(fix.manager.target == .apple)
        #expect(fix.manager.jobComponents() == [.speakerID])

        // Whisper target
        await fix.manager.choose(.whisper)
        #expect(fix.manager.jobComponents() == .all)
    }

    @Test("isReady checks both availability and download state")
    func isReadyChecks() async throws {
        let fix = try makeManager(
            installed: ["en_US"],
            whisperPresent: false
        )

        await fix.manager.refresh()

        // Apple: available + downloaded -> ready
        #expect(fix.manager.isReady(.apple) == true)
        // Whisper: not downloaded -> not ready
        #expect(fix.manager.isReady(.whisper) == false)
    }

    @Test("isAnyDownloadInFlight detects downloading state")
    func isAnyDownloadInFlight() async throws {
        let fix = try makeManager()

        await fix.manager.refresh()
        #expect(fix.manager.isAnyDownloadInFlight == false)

        fix.manager.speakerID = .downloading(fraction: 0.3)
        #expect(fix.manager.isAnyDownloadInFlight == true)
    }
}
