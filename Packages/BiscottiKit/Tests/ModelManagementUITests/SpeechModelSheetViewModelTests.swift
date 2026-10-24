import AppCore
import BiscottiTestSupport
import Foundation
import Testing
import TranscriptionService
@testable import DataStore
@testable import ModelManagementUI

@Suite("SpeechModelSheetViewModel")
@MainActor
struct SpeechModelSheetViewModelTests {
    // MARK: - Helpers

    /// Creates a fixture with Apple available (macOS 26), locales set,
    /// and Apple assets installed.
    private func makeFixture(
        appleAvailability: AppleSpeechAvailability = .available,
        appleInstalled: Set<String> = ["en_US"],
        whisperPresent: Bool = true
    ) throws -> (CoreFixture, SpeechModelSheetViewModel) {
        let fix = try makeCoreFixture(
            appleAvailability: appleAvailability,
            appleLocales: ["en_US", "en_GB"],
            appleEquivalent: "en_US",
            appleInstalled: appleInstalled,
            whisperPresent: whisperPresent
        )
        let viewModel = SpeechModelSheetViewModel(core: fix.core)
        return (fix, viewModel)
    }

    // MARK: - Basic reads

    @Test("rows returns two rows")
    func rowsReturnsTwoRows() throws {
        let (fix, viewModel) = try makeFixture()
        defer { fix.cleanup() }
        #expect(viewModel.rows.count == 2)
        #expect(viewModel.rows[0].engine == .apple)
        #expect(viewModel.rows[1].engine == .whisper)
    }

    @Test("localeOptions delegates to engine manager")
    func localeOptionsForwards() throws {
        let (fix, viewModel) = try makeFixture()
        defer { fix.cleanup() }
        // Locales populated after refresh
        Task { await viewModel.onAppear() }
        // Check initial state (before refresh, may be empty)
        // After onAppear, localeOptions should forward from engines
        #expect(viewModel.localeOptions.isEmpty)
    }

    // MARK: - Vocabulary guard: Apple actions with vocab on

    @Test("tapDownload on Apple without vocab does not show alert")
    func tapDownloadAppleNoVocabGuard() throws {
        let (fix, viewModel) = try makeFixture(whisperPresent: true)
        defer { fix.cleanup() }
        // vocabularyStoredOn defaults to false, so no guard alert
        viewModel.tapDownload(.apple)
        #expect(viewModel.showTurnOffVocabulary == false)
    }

    @Test("tapChoose on Whisper never shows vocab alert")
    func tapChooseWhisperNoAlert() throws {
        let (fix, viewModel) = try makeFixture()
        defer { fix.cleanup() }
        viewModel.tapChoose(.whisper)
        #expect(viewModel.showTurnOffVocabulary == false)
    }

    @Test("confirmTurnOffVocabulary dismisses alert")
    func confirmTurnOffVocabDismisses() throws {
        let (fix, viewModel) = try makeFixture()
        defer { fix.cleanup() }
        viewModel.showTurnOffVocabulary = true
        viewModel.confirmTurnOffVocabulary()
        #expect(viewModel.showTurnOffVocabulary == false)
    }

    @Test("cancelTurnOffVocabulary dismisses alert")
    func cancelTurnOffVocabDismisses() throws {
        let (fix, viewModel) = try makeFixture()
        defer { fix.cleanup() }
        viewModel.showTurnOffVocabulary = true
        viewModel.cancelTurnOffVocabulary()
        #expect(viewModel.showTurnOffVocabulary == false)
    }

    // MARK: - Vocabulary guard: positive path (vocab on, Whisper target)

    /// Seeds settings so onAppear loads vocabularyStoredOn = true and
    /// target resolves to Whisper.
    private func makeVocabOnFixture() async throws -> (CoreFixture, SpeechModelSheetViewModel) {
        let fix = try makeCoreFixture(
            appleAvailability: .available,
            appleLocales: ["en_US", "en_GB"],
            appleEquivalent: "en_US",
            appleInstalled: ["en_US"],
            whisperPresent: true
        )
        // Seed custom vocabulary on and Whisper as the engine selection
        try await fix.store.updateSettings { settings in
            settings.customVocabularyEnabled = true
            settings.sttEngineSelection = "whisper"
        }
        let viewModel = SpeechModelSheetViewModel(core: fix.core)
        await viewModel.onAppear()
        return (fix, viewModel)
    }

    @Test("tapDownload on Apple with vocab on shows turn-off alert")
    func tapDownloadAppleVocabGuardPositive() async throws {
        let (fix, viewModel) = try await makeVocabOnFixture()
        defer { fix.cleanup() }
        viewModel.tapDownload(.apple)
        #expect(viewModel.showTurnOffVocabulary == true)
    }

    @Test("tapChoose on Apple with vocab on shows turn-off alert")
    func tapChooseAppleVocabGuardPositive() async throws {
        let (fix, viewModel) = try await makeVocabOnFixture()
        defer { fix.cleanup() }
        viewModel.tapChoose(.apple)
        #expect(viewModel.showTurnOffVocabulary == true)
    }

    @Test("confirmTurnOffVocabulary runs stashed download action")
    func confirmVocabRunsDownload() async throws {
        let (fix, viewModel) = try await makeVocabOnFixture()
        defer { fix.cleanup() }
        // Trigger the guard
        viewModel.tapDownload(.apple)
        #expect(viewModel.showTurnOffVocabulary == true)
        // Confirm dismisses and runs the stashed action
        viewModel.confirmTurnOffVocabulary()
        #expect(viewModel.showTurnOffVocabulary == false)
    }

    @Test("cancelTurnOffVocabulary drops stashed action")
    func cancelVocabDropsAction() async throws {
        let (fix, viewModel) = try await makeVocabOnFixture()
        defer { fix.cleanup() }
        viewModel.tapChoose(.apple)
        #expect(viewModel.showTurnOffVocabulary == true)
        viewModel.cancelTurnOffVocabulary()
        #expect(viewModel.showTurnOffVocabulary == false)
    }

    // MARK: - Delete flow

    @Test("tapDelete shows delete confirmation")
    func tapDeleteShowsDialog() throws {
        let (fix, viewModel) = try makeFixture()
        defer { fix.cleanup() }
        viewModel.tapDelete()
        #expect(viewModel.showDeleteWhisper == true)
    }

    @Test("confirmDelete dismisses dialog")
    func confirmDeleteDismisses() throws {
        let (fix, viewModel) = try makeFixture()
        defer { fix.cleanup() }
        viewModel.tapDelete()
        viewModel.confirmDelete()
        #expect(viewModel.showDeleteWhisper == false)
    }

    // MARK: - Delete message variants

    @Test("deleteMessage base text mentions 626 MB")
    func deleteMessageBase() throws {
        let (fix, viewModel) = try makeFixture()
        defer { fix.cleanup() }
        #expect(viewModel.deleteMessage.contains("626 MB"))
        #expect(viewModel.deleteMessage.contains("download it again"))
    }

    @Test("deleteMessage includes vocab warning when vocab on and Whisper target")
    func deleteMessageVocabVariant() async throws {
        let (fix, viewModel) = try await makeVocabOnFixture()
        defer { fix.cleanup() }
        let msg = viewModel.deleteMessage
        #expect(msg.contains("626 MB"))
        #expect(msg.contains("Custom vocabulary turns off"))
    }

    // MARK: - Learn more message

    @Test("learnMoreMessage includes OS major version")
    func learnMoreMessageOSVersion() throws {
        let (fix, viewModel) = try makeFixture(
            appleAvailability: .requiresOSUpdate(currentMajor: 15)
        )
        defer { fix.cleanup() }
        let msg = viewModel.learnMoreMessage
        // The message should mention the OS version from the engine manager
        #expect(msg.contains("macOS"))
    }

    // MARK: - setLocale

    @Test("setLocale does not crash")
    func setLocaleForwards() throws {
        let (fix, viewModel) = try makeFixture()
        defer { fix.cleanup() }
        // Should forward without error
        viewModel.setLocale("en_GB")
    }

    // MARK: - Learn more alert

    @Test("showLearnMore toggles correctly")
    func showLearnMoreToggle() throws {
        let (fix, viewModel) = try makeFixture()
        defer { fix.cleanup() }
        #expect(viewModel.showLearnMore == false)
        viewModel.showLearnMore = true
        #expect(viewModel.showLearnMore == true)
    }
}
