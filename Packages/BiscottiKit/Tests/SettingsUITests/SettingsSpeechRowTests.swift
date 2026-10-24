import AppCore
import BiscottiTestSupport
import Testing
import TranscriptionService
@testable import SettingsUI

@Suite("SettingsViewModel -- Speech to Text Model row")
@MainActor
struct SettingsSpeechRowTests {
    // MARK: - speechTargetReady

    @Test("speechTargetReady is false when target is not downloaded")
    func targetNotReady() async throws {
        // Default fixture: Apple requires OS update, Whisper not present
        let fix = try makeCoreFixture(
            appleAvailability: .requiresOSUpdate(currentMajor: 15),
            whisperPresent: false
        )
        defer { fix.cleanup() }

        let viewModel = SettingsViewModel(core: fix.core)
        await viewModel.load()
        #expect(viewModel.speechTargetReady == false)
    }

    @Test("speechTargetReady is true when Whisper is downloaded")
    func targetReadyWhisper() async throws {
        let fix = try makeCoreFixture(whisperPresent: true)
        defer { fix.cleanup() }

        let viewModel = SettingsViewModel(core: fix.core)
        await fix.speechEngines.refresh()
        #expect(viewModel.speechTargetReady == true)
    }

    // MARK: - speechSummaryLabel

    @Test("speechSummaryLabel forwards engine manager label")
    func summaryLabelForwards() async throws {
        let fix = try makeCoreFixture(whisperPresent: true)
        defer { fix.cleanup() }

        let viewModel = SettingsViewModel(core: fix.core)
        await fix.speechEngines.refresh()
        let label = viewModel.speechSummaryLabel
        // Whisper summary label should contain "Whisper"
        #expect(label.contains("Whisper"))
    }

    // MARK: - load refreshes speech engines

    @Test("load calls speechEngines.refresh")
    func loadRefreshesSpeechEngines() async throws {
        let fix = try makeCoreFixture(
            appleAvailability: .available,
            appleLocales: ["en_US"],
            appleEquivalent: "en_US",
            appleInstalled: ["en_US"],
            whisperPresent: true
        )
        defer { fix.cleanup() }

        let viewModel = SettingsViewModel(core: fix.core)
        await viewModel.load()

        // After load, speechTargetReady should reflect the refreshed state
        #expect(viewModel.speechTargetReady == true)
    }
}
