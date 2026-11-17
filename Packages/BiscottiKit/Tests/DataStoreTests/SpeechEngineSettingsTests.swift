import DataStore
import Foundation
import Testing

private func makeStore() throws -> DataStore {
    try DataStore(storage: .inMemory)
}

@Suite("DataStore -- speech engine settings")
struct SpeechEngineSettingsTests {
    @Test("sttEngineSelection defaults to empty string")
    func sttEngineSelectionDefault() async throws {
        let store = try makeStore()
        let settings = try await store.settings()
        #expect(settings.sttEngineSelection == "")
    }

    @Test("appleSpeechLocale defaults to empty string")
    func appleSpeechLocaleDefault() async throws {
        let store = try makeStore()
        let settings = try await store.settings()
        #expect(settings.appleSpeechLocale == "")
    }

    @Test("sttEngineSelection round-trips through updateSettings")
    func sttEngineSelectionRoundTrip() async throws {
        let store = try makeStore()
        try await store.updateSettings { $0.sttEngineSelection = "whisper" }
        let settings = try await store.settings()
        #expect(settings.sttEngineSelection == "whisper")
    }

    @Test("appleSpeechLocale round-trips through updateSettings")
    func appleSpeechLocaleRoundTrip() async throws {
        let store = try makeStore()
        try await store.updateSettings { $0.appleSpeechLocale = "en_GB" }
        let settings = try await store.settings()
        #expect(settings.appleSpeechLocale == "en_GB")
    }
}
