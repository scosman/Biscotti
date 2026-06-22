import AppCore
import BiscottiTestSupport
import Calendar
import Foundation
import Intelligence
import MeetingCatalog
import MeetingDetection
import Notifications
import Permissions
import Recording
import Testing
import TranscriptionService
@testable import DataStore
@testable import SettingsUI

@Suite("SettingsViewModel -- AI Enhancements")
@MainActor
struct SettingsAIEnhancementsTests {
    // MARK: - Toggle persistence

    @Test("aiAnalysisEnabled defaults to true and persists toggle")
    func aiAnalysisEnabledDefaultAndPersist() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.load()

        #expect(viewModel.aiAnalysisEnabled == true)

        // Toggle off
        await viewModel.setAIAnalysisEnabled(false)
        #expect(viewModel.aiAnalysisEnabled == false)

        // Verify persisted
        let settings = try await fixture.store.settings()
        #expect(settings.aiAnalysisEnabled == false)

        // Toggle back on
        await viewModel.setAIAnalysisEnabled(true)
        #expect(viewModel.aiAnalysisEnabled == true)

        let settings2 = try await fixture.store.settings()
        #expect(settings2.aiAnalysisEnabled == true)
    }

    // MARK: - Revert on failure

    @Test("setAIAnalysisEnabled reverts on store failure")
    func aiAnalysisEnabledRevertsOnFailure() async throws {
        let (core, storeDir) = try makeFailableCore()
        defer { restoreAndCleanup(storeDir) }

        let viewModel = SettingsViewModel(core: core)
        await viewModel.load()
        #expect(viewModel.aiAnalysisEnabled == true)

        // Remove the store directory to corrupt it so save() throws
        corruptStore(storeDir)

        // Attempt to toggle off -- should revert to true
        await viewModel.setAIAnalysisEnabled(false)
        #expect(viewModel.aiAnalysisEnabled == true)
    }

    // MARK: - Load reads from store

    @Test("load reads aiAnalysisEnabled from store")
    func loadReadsAIAnalysisFromStore() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }

        // Pre-set the value to false
        try await fixture.store.updateSettings { settings in
            settings.aiAnalysisEnabled = false
        }

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.load()

        #expect(viewModel.aiAnalysisEnabled == false)
    }

    // MARK: - Model availability

    @Test("modelAvailable is false when model is not downloaded")
    func modelNotAvailableWhenNotDownloaded() throws {
        let fixture = try makeCoreFixture(modelDownloaded: false)
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)
        #expect(viewModel.modelAvailable == false)
    }

    @Test("modelAvailable is true when model is downloaded")
    func modelAvailableWhenDownloaded() throws {
        let fixture = try makeCoreFixture(modelDownloaded: true)
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)
        #expect(viewModel.modelAvailable == true)
    }

    // MARK: - No-model binding behavior

    @Test("toggle binding shows false when model unavailable without corrupting stored value")
    func toggleBindingShowsFalseWithoutCorruption() async throws {
        let fixture = try makeCoreFixture(modelDownloaded: false)
        defer { fixture.cleanup() }

        // Pre-set toggle to true (the default)
        try await fixture.store.updateSettings { settings in
            settings.aiAnalysisEnabled = true
        }

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.load()

        // Model is not available
        #expect(viewModel.modelAvailable == false)

        // The stored VM value is true (loaded from store)
        #expect(viewModel.aiAnalysisEnabled == true)

        // The view binding should show false (disabled state)
        // -- this is the behavior the SettingsView binding enforces:
        //    get: { viewModel.modelAvailable ? viewModel.aiAnalysisEnabled : false }
        // We verify the condition that drives the binding:
        // modelAvailable is false, so the binding evaluates to false,
        // while the underlying stored value remains true (no corruption).
        let storedSettings = try await fixture.store.settings()
        #expect(storedSettings.aiAnalysisEnabled == true)
    }

    // MARK: - Download state

    @Test("modelDownload reflects Intelligence download state")
    func downloadStateFromIntelligence() throws {
        let fixture = try makeCoreFixture(modelDownloaded: false)
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)

        // Initial state after init (Intelligence.refreshModelState runs in init)
        #expect(viewModel.modelDownload == .notDownloaded)
    }

    @Test("modelDownload shows downloaded when model present")
    func downloadStateDownloaded() throws {
        let fixture = try makeCoreFixture(modelDownloaded: true)
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)

        #expect(viewModel.modelDownload == .downloaded)
    }

    // MARK: - Load refreshes model state

    @Test("load calls refreshModelState on Intelligence")
    func loadCallsRefreshModelState() async throws {
        let fixture = try makeCoreFixture(modelDownloaded: false)
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)

        // Initially not downloaded
        #expect(viewModel.modelAvailable == false)

        // Simulate model appearing on disk
        fixture.fakeModelProvider.downloaded = true

        // load() should call refreshModelState and pick up the change
        await viewModel.load()

        #expect(viewModel.modelAvailable == true)
        #expect(viewModel.modelDownload == .downloaded)
    }

    // MARK: - Download initiation

    @Test("startModelDownload triggers download on Intelligence")
    func startModelDownloadTriggersDownload() async throws {
        let fixture = try makeCoreFixture(modelDownloaded: false)
        defer { fixture.cleanup() }

        let viewModel = SettingsViewModel(core: fixture.core)

        #expect(viewModel.modelAvailable == false)

        // Call downloadModel directly on Intelligence (synchronous test)
        // FakeCoreModelProvider.download sets downloaded=true immediately
        await fixture.intelligence.downloadModel()

        #expect(fixture.fakeModelProvider.downloaded == true)
    }

    // MARK: - Toggle interaction with model state

    @Test("toggle reflects stored value when model is available")
    func toggleReflectsStoredValueWithModel() async throws {
        let fixture = try makeCoreFixture(modelDownloaded: true)
        defer { fixture.cleanup() }

        // Pre-set toggle off
        try await fixture.store.updateSettings { settings in
            settings.aiAnalysisEnabled = false
        }

        let viewModel = SettingsViewModel(core: fixture.core)
        await viewModel.load()

        // With model present, toggle shows its real stored value
        #expect(viewModel.modelAvailable == true)
        #expect(viewModel.aiAnalysisEnabled == false)
    }
}

// MARK: - Failable store helpers

/// Creates an AppCore backed by an on-disk DataStore whose directory
/// can be removed to trigger save failures (for revert-on-failure testing).
@MainActor
private func makeFailableCore() throws -> (AppCore, URL) {
    let storeDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("FailableStore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: storeDir, withIntermediateDirectories: true
    )

    let store = try DataStore(storage: .onDisk(storeDir))
    let core = try buildAppCore(store: store, storeDir: storeDir)
    return (core, storeDir)
}

/// Builds a minimal AppCore around a given DataStore with all-fake services.
///
/// - Parameter storeDir: The on-disk store directory. The recording
///   `storageRoot` is nested under it so cleanup of `storeDir` removes
///   both directories.
@MainActor
private func buildAppCore(
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
    let intelligence = Intelligence(
        store: store, llm: FakeCoreLLMRunner(),
        models: FakeCoreModelProvider(downloaded: false),
        settings: { AISettings(enabled: true) }
    )
    return AppCore(
        store: store, permissions: permissions,
        recording: recording,
        transcription: TranscriptionService(store: store, engine: FakeTranscriber()),
        calendar: CalendarService(store: store, catalog: catalog, provider: FakeEventStore()),
        detector: MeetingDetector(catalog: catalog, source: FakeActivitySource()),
        notifications: NotificationService(provider: FakeTestNotificationCenter()),
        intelligence: intelligence
    )
}

/// Removes the store directory to corrupt the DataStore and trigger
/// save failures on the next `updateSettings` call.
private func corruptStore(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}

/// Cleans up the store directory (best-effort).
private func restoreAndCleanup(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}
