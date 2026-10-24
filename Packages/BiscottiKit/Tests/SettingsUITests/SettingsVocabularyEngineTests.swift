import BiscottiTestSupport
import Foundation
import Testing
import Transcription
import TranscriptionService
@testable import DataStore
@testable import SettingsUI

@Suite("SettingsViewModel -- vocabulary engine gating")
@MainActor
struct SettingsVocabularyEngineTests {
    // MARK: - Effective display

    @Test("customVocabularyDisplayed is false when target is Apple")
    func displayedFalseWhenApple() async throws {
        let fix = try makeCoreFixture(
            appleAvailability: .available,
            appleLocales: ["en_US"],
            appleEquivalent: "en_US",
            appleInstalled: ["en_US"],
            testName: "SettingsVocabEngine"
        )
        defer { fix.cleanup() }

        await fix.speechEngines.refresh()
        await fix.speechEngines.choose(.apple)

        // Enable the stored preference
        try await fix.store.updateSettings {
            $0.customVocabularyEnabled = true
        }

        let viewModel = SettingsViewModel(core: fix.core)
        await viewModel.load()

        // Stored preference is on, but target is Apple -> displayed is false
        #expect(viewModel.customVocabularyEnabled == true)
        #expect(viewModel.customVocabularyDisplayed == false)
    }

    @Test("customVocabularyDisplayed is true when target is Whisper")
    func displayedTrueWhenWhisper() async throws {
        let fix = try makeCoreFixture(
            whisperPresent: true,
            testName: "SettingsVocabEngine"
        )
        defer { fix.cleanup() }

        await fix.speechEngines.refresh()

        // Enable the stored preference
        try await fix.store.updateSettings {
            $0.customVocabularyEnabled = true
        }

        let viewModel = SettingsViewModel(core: fix.core)
        await viewModel.load()

        #expect(viewModel.customVocabularyEnabled == true)
        #expect(viewModel.customVocabularyDisplayed == true)
    }

    // MARK: - Alert gating

    @Test("requestCustomVocabularyEnabled shows alert when target is Apple")
    func alertShownWhenApple() async throws {
        let fix = try makeCoreFixture(
            appleAvailability: .available,
            appleLocales: ["en_US"],
            appleEquivalent: "en_US",
            appleInstalled: ["en_US"],
            testName: "SettingsVocabEngine"
        )
        defer { fix.cleanup() }

        await fix.speechEngines.refresh()
        await fix.speechEngines.choose(.apple)

        let viewModel = SettingsViewModel(core: fix.core)
        await viewModel.load()

        await viewModel.requestCustomVocabularyEnabled(true)

        #expect(viewModel.showRequiresWhisperAlert == true)
        // Did not actually enable
        #expect(viewModel.customVocabularyEnabled == false)
    }

    @Test("requestCustomVocabularyEnabled passes through when target is Whisper")
    func noAlertWhenWhisper() async throws {
        let fix = try makeCoreFixture(
            whisperPresent: true,
            testName: "SettingsVocabEngine"
        )
        defer { fix.cleanup() }

        await fix.speechEngines.refresh()

        let viewModel = SettingsViewModel(core: fix.core)
        await viewModel.load()

        await viewModel.requestCustomVocabularyEnabled(true)

        #expect(viewModel.showRequiresWhisperAlert == false)
        #expect(viewModel.customVocabularyEnabled == true)
    }

    // MARK: - Switch to Whisper

    @Test("switchToWhisperForVocabulary downloads Whisper and enables vocab")
    func switchDownloadsAndEnables() async throws {
        let fix = try makeCoreFixture(
            appleAvailability: .available,
            appleLocales: ["en_US"],
            appleEquivalent: "en_US",
            appleInstalled: ["en_US"],
            testName: "SettingsVocabEngine"
        )
        defer { fix.cleanup() }

        await fix.speechEngines.refresh()
        await fix.speechEngines.choose(.apple)

        let viewModel = SettingsViewModel(core: fix.core)
        await viewModel.load()
        viewModel.showRequiresWhisperAlert = true

        await viewModel.switchToWhisperForVocabulary()

        #expect(viewModel.showRequiresWhisperAlert == false)
        #expect(viewModel.customVocabularyEnabled == true)
        #expect(fix.speechEngines.selection == .whisper)
    }

    @Test("switchToWhisperForVocabulary chooses when already downloaded")
    func switchChoosesWhenDownloaded() async throws {
        let fix = try makeCoreFixture(
            appleAvailability: .available,
            appleLocales: ["en_US"],
            appleEquivalent: "en_US",
            appleInstalled: ["en_US"],
            whisperPresent: true,
            testName: "SettingsVocabEngine"
        )
        defer { fix.cleanup() }

        await fix.speechEngines.refresh()
        await fix.speechEngines.choose(.apple)

        let viewModel = SettingsViewModel(core: fix.core)
        await viewModel.load()

        await viewModel.switchToWhisperForVocabulary()

        #expect(fix.speechEngines.selection == .whisper)
        #expect(viewModel.customVocabularyEnabled == true)
    }

    // MARK: - Alert message variants

    @Test("requiresWhisperAlertMessage when Whisper is ready")
    func alertMessageWhenWhisperReady() async throws {
        let fix = try makeCoreFixture(
            appleAvailability: .available,
            appleLocales: ["en_US"],
            appleEquivalent: "en_US",
            appleInstalled: ["en_US"],
            whisperPresent: true,
            testName: "SettingsVocabEngine"
        )
        defer { fix.cleanup() }

        await fix.speechEngines.refresh()
        await fix.speechEngines.choose(.apple)

        let viewModel = SettingsViewModel(core: fix.core)
        await viewModel.load()

        #expect(viewModel.requiresWhisperAlertMessage.contains("Switching uses Whisper"))
    }

    @Test("requiresWhisperAlertMessage when Whisper is not ready")
    func alertMessageWhenWhisperNotReady() async throws {
        let fix = try makeCoreFixture(
            appleAvailability: .available,
            appleLocales: ["en_US"],
            appleEquivalent: "en_US",
            appleInstalled: ["en_US"],
            testName: "SettingsVocabEngine"
        )
        defer { fix.cleanup() }

        await fix.speechEngines.refresh()
        await fix.speechEngines.choose(.apple)

        let viewModel = SettingsViewModel(core: fix.core)
        await viewModel.load()

        #expect(viewModel.requiresWhisperAlertMessage.contains("downloads Whisper"))
    }
}
