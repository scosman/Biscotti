import AppCore
import BiscottiTestSupport
import Calendar
import Foundation
import Intelligence
import LocalLLM
import MeetingCatalog
import MeetingDetection
import Notifications
import Permissions
import Recording
import Testing
import TranscriptionService
import Vocabulary
@testable import DataStore
@testable import SettingsUI

@Suite("SettingsViewModel -- Custom Vocabulary")
@MainActor
struct SettingsVocabularyTests {
    // MARK: - Toggle persistence

    @Test("customVocabularyEnabled defaults to true and persists toggle")
    func customVocabularyEnabledDefaultAndPersist() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.load()
        #expect(viewModel.customVocabularyEnabled == true)

        await viewModel.setCustomVocabularyEnabled(false)
        #expect(viewModel.customVocabularyEnabled == false)

        let settings = try await fixture.store.settings()
        #expect(settings.customVocabularyEnabled == false)

        await viewModel.setCustomVocabularyEnabled(true)
        #expect(viewModel.customVocabularyEnabled == true)

        let settings2 = try await fixture.store.settings()
        #expect(settings2.customVocabularyEnabled == true)
    }

    @Test("calendarVocabularyEnabled defaults to true and persists toggle")
    func calendarVocabularyEnabledDefaultAndPersist() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.load()
        #expect(viewModel.calendarVocabularyEnabled == true)

        await viewModel.setCalendarVocabularyEnabled(false)
        #expect(viewModel.calendarVocabularyEnabled == false)

        let settings = try await fixture.store.settings()
        #expect(settings.calendarVocabularyEnabled == false)

        await viewModel.setCalendarVocabularyEnabled(true)
        #expect(viewModel.calendarVocabularyEnabled == true)

        let settings2 = try await fixture.store.settings()
        #expect(settings2.calendarVocabularyEnabled == true)
    }

    // MARK: - Load from store

    @Test("load reads vocabulary settings from store")
    func loadReadsVocabularySettingsFromStore() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        try await fixture.store.updateSettings { settings in
            settings.customVocabularyEnabled = false
            settings.calendarVocabularyEnabled = false
            settings.customVocabulary = ["Alpha", "Beta"]
        }

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.load()

        #expect(viewModel.customVocabularyEnabled == false)
        #expect(viewModel.calendarVocabularyEnabled == false)
        #expect(viewModel.vocabularyTerms == ["Alpha", "Beta"])
    }

    // MARK: - Add term

    @Test("addVocabularyTerm persists to store")
    func addVocabularyTermPersists() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.load()
        #expect(viewModel.vocabularyTerms.isEmpty)

        let result = await viewModel.addVocabularyTerm("Kubernetes")
        #expect(result == nil)
        #expect(viewModel.vocabularyTerms == ["Kubernetes"])

        let settings = try await fixture.store.settings()
        #expect(settings.customVocabulary == ["Kubernetes"])
    }

    @Test("addVocabularyTerm trims whitespace")
    func addVocabularyTermTrimsWhitespace() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.load()

        let result = await viewModel.addVocabularyTerm("  Acme  ")
        #expect(result == nil)
        #expect(viewModel.vocabularyTerms == ["Acme"])
    }

    @Test("addVocabularyTerm ignores whitespace-only input")
    func addVocabularyTermIgnoresWhitespace() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.load()

        let result = await viewModel.addVocabularyTerm("   ")
        #expect(result == nil)
        #expect(viewModel.vocabularyTerms.isEmpty)
    }

    @Test("addVocabularyTerm rejects case-insensitive duplicate")
    func addVocabularyTermRejectsDuplicate() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.load()

        let firstResult = await viewModel.addVocabularyTerm("Acme")
        #expect(firstResult == nil)

        let secondResult = await viewModel.addVocabularyTerm("acme")
        #expect(secondResult == .duplicate("Acme"))
        #expect(viewModel.vocabularyTerms == ["Acme"])
    }

    @Test("addVocabularyTerm rejects term exceeding max length")
    func addVocabularyTermRejectsTooLong() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.load()

        let longTerm = String(repeating: "a", count: VocabularyLimits.maxSingleTermLength + 1)
        let result = await viewModel.addVocabularyTerm(longTerm)
        #expect(result == .tooLong)
        #expect(viewModel.vocabularyTerms.isEmpty)
    }

    @Test("addVocabularyTerm accepts term at exact max length")
    func addVocabularyTermAcceptsExactMaxLength() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.load()

        let exactTerm = String(repeating: "a", count: VocabularyLimits.maxSingleTermLength)
        let result = await viewModel.addVocabularyTerm(exactTerm)
        #expect(result == nil)
        #expect(viewModel.vocabularyTerms.count == 1)
    }

    // MARK: - Remove term

    @Test("removeVocabularyTerm persists removal")
    func removeVocabularyTermPersists() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.load()

        _ = await viewModel.addVocabularyTerm("Alpha")
        _ = await viewModel.addVocabularyTerm("Beta")
        #expect(viewModel.vocabularyTerms == ["Alpha", "Beta"])

        await viewModel.removeVocabularyTerm(at: 0)
        #expect(viewModel.vocabularyTerms == ["Beta"])

        let settings = try await fixture.store.settings()
        #expect(settings.customVocabulary == ["Beta"])
    }

    // MARK: - Update term

    @Test("updateVocabularyTerm persists edit")
    func updateVocabularyTermPersists() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.load()

        _ = await viewModel.addVocabularyTerm("Alph")
        let result = await viewModel.updateVocabularyTerm(at: 0, to: "Alpha")
        #expect(result == nil)
        #expect(viewModel.vocabularyTerms == ["Alpha"])

        let settings = try await fixture.store.settings()
        #expect(settings.customVocabulary == ["Alpha"])
    }

    @Test("updateVocabularyTerm rejects duplicate against another term")
    func updateVocabularyTermRejectsDuplicate() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.load()

        _ = await viewModel.addVocabularyTerm("Alpha")
        _ = await viewModel.addVocabularyTerm("Beta")

        let result = await viewModel.updateVocabularyTerm(at: 1, to: "alpha")
        #expect(result == .duplicate("Alpha"))
        #expect(viewModel.vocabularyTerms == ["Alpha", "Beta"])
    }

    @Test("updateVocabularyTerm allows re-casing same term")
    func updateVocabularyTermAllowsReCasing() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.load()

        _ = await viewModel.addVocabularyTerm("alpha")
        let result = await viewModel.updateVocabularyTerm(at: 0, to: "Alpha")
        #expect(result == nil)
        #expect(viewModel.vocabularyTerms == ["Alpha"])
    }

    // MARK: - Revert on failure

    @Test("setCustomVocabularyEnabled reverts on store failure")
    func customVocabularyEnabledRevertsOnFailure() async throws {
        let (core, storeDir) = try makeFailableVocabCore()
        defer { cleanupFailableStore(storeDir) }

        let viewModel = SettingsViewModel(core: core)
        await viewModel.load()
        #expect(viewModel.customVocabularyEnabled == true)

        corruptVocabStore(storeDir)

        await viewModel.setCustomVocabularyEnabled(false)
        #expect(viewModel.customVocabularyEnabled == true)
    }

    @Test("setCalendarVocabularyEnabled reverts on store failure")
    func calendarVocabularyEnabledRevertsOnFailure() async throws {
        let (core, storeDir) = try makeFailableVocabCore()
        defer { cleanupFailableStore(storeDir) }

        let viewModel = SettingsViewModel(core: core)
        await viewModel.load()
        #expect(viewModel.calendarVocabularyEnabled == true)

        corruptVocabStore(storeDir)

        await viewModel.setCalendarVocabularyEnabled(false)
        #expect(viewModel.calendarVocabularyEnabled == true)
    }

    // MARK: - Term count

    @Test("vocabularyTerms count reflects add and remove")
    func vocabularyTermsCountReflectsChanges() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.load()
        #expect(viewModel.vocabularyTerms.isEmpty)

        _ = await viewModel.addVocabularyTerm("One")
        _ = await viewModel.addVocabularyTerm("Two")
        _ = await viewModel.addVocabularyTerm("Three")
        #expect(viewModel.vocabularyTerms.count == 3)

        await viewModel.removeVocabularyTerm(at: 1)
        #expect(viewModel.vocabularyTerms.count == 2)
        #expect(viewModel.vocabularyTerms == ["One", "Three"])
    }
}

// MARK: - Failable store helpers (mirrored from SettingsAIEnhancementsTests)

@MainActor
private func makeFailableVocabCore() throws -> (AppCore, URL) {
    let storeDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("FailableVocabStore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: storeDir, withIntermediateDirectories: true
    )

    let store = try DataStore(storage: .onDisk(storeDir))
    let core = try buildFailableVocabCore(store: store, storeDir: storeDir)
    return (core, storeDir)
}

@MainActor
private func buildFailableVocabCore(
    store: DataStore, storeDir: URL
) throws -> AppCore {
    let permissions = Permissions(
        mic: FakeMicAuthorizer(status: .authorized, requestResult: true),
        systemAudioStore: InMemorySystemAudioPermissionStore()
    )
    let storageRoot = storeDir.appendingPathComponent("recordings")
    try FileManager.default.createDirectory(
        at: storageRoot, withIntermediateDirectories: true
    )
    let recording = RecordingController(
        store: store, permissions: permissions,
        storageRoot: storageRoot, makeRecorder: { FakeRecorder() }
    )
    let catalog = BundledMeetingCatalog()
    let fakeModelProvider = FakeCoreModelProvider(downloaded: false)
    let fakeHardwareProbe = FakeCoreHardwareProbe()
    let modelManager = ModelManager(
        store: store,
        models: fakeModelProvider,
        hardware: fakeHardwareProbe
    )
    let intelligence = Intelligence(
        store: store, llm: FakeCoreLLMRunner(),
        modelManager: modelManager,
        settings: { AISettings(enabled: true) }
    )
    return AppCore(
        store: store, permissions: permissions,
        recording: recording,
        transcription: TranscriptionService(
            store: store, engine: FakeTranscriber(),
            vocabulary: VocabularyService(store: store)
        ),
        calendar: CalendarService(
            store: store, catalog: catalog,
            provider: FakeEventStore()
        ),
        detector: MeetingDetector(
            catalog: catalog, source: FakeActivitySource()
        ),
        notifications: NotificationService(
            provider: FakeTestNotificationCenter()
        ),
        intelligence: intelligence,
        modelManager: modelManager
    )
}

private func corruptVocabStore(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}

private func cleanupFailableStore(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}
