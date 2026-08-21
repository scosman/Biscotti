import DataStore
import Testing

@Suite("DataStore -- transcription language round-trip")
struct TranscriptionLanguageSettingsTests {
    @Test("settings default the transcription language to auto")
    func defaultsToAuto() async throws {
        let store = try DataStore(storage: .inMemory)
        let settings = try await store.settings()
        #expect(settings.transcriptionLanguage == .auto)
    }

    @Test("updateSettings persists the transcription language")
    func updateSettingsPersists() async throws {
        let store = try DataStore(storage: .inMemory)
        try await store.updateSettings { settings in
            settings.transcriptionLanguage = .russian
        }

        let result = try await store.settings()
        #expect(result.transcriptionLanguage == .russian)
    }

    @Test("every language round-trips through the store")
    func everyLanguageRoundTrips() async throws {
        let store = try DataStore(storage: .inMemory)
        for language in TranscriptionLanguage.allCases {
            try await store.updateSettings { settings in
                settings.transcriptionLanguage = language
            }
            let result = try await store.settings()
            #expect(result.transcriptionLanguage == language)
        }
    }
}
