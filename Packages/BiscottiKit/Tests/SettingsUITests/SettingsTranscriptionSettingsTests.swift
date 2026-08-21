import AppCore
import BiscottiTestSupport
import DataStore
import Foundation
import Testing
@testable import SettingsUI

@Suite("SettingsViewModel -- transcription settings")
@MainActor
struct SettingsTranscriptionSettingsTests {
    @Test("transcriptionLanguage defaults to auto")
    func languageDefault() throws {
        let fix = try makeCoreFixture()
        defer { fix.cleanup() }
        let viewModel = SettingsViewModel(core: fix.core)
        #expect(viewModel.transcriptionLanguage == .auto)
    }

    @Test("load populates the transcription language from the store")
    func loadPopulatesLanguage() async throws {
        let fix = try makeCoreFixture()
        defer { fix.cleanup() }

        try await fix.store.updateSettings { settings in
            settings.transcriptionLanguage = .russian
        }

        let viewModel = SettingsViewModel(core: fix.core)
        await viewModel.load()

        #expect(viewModel.transcriptionLanguage == .russian)
    }

    @Test("setTranscriptionLanguage persists the choice")
    func setLanguagePersists() async throws {
        let fix = try makeCoreFixture()
        defer { fix.cleanup() }
        let viewModel = SettingsViewModel(core: fix.core)

        await viewModel.setTranscriptionLanguage(.russian)
        #expect(viewModel.transcriptionLanguage == .russian)

        let settings = try await fix.store.settings()
        #expect(settings.transcriptionLanguage == .russian)
    }
}
