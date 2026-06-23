import DataStore
import Foundation
import LocalLLM
import Testing
import Transcription
@testable import Intelligence

// MARK: - Fakes

/// Fake model provider with configurable per-model download state.
private final class MMFakeModelProvider: ModelProviding,
    @unchecked Sendable
{
    let catalog: [LLMModel]
    var downloadedIDs: Set<String>

    var downloadShouldFail = false
    var downloadCalledIDs: [String] = []

    init(downloadedIDs: Set<String> = []) {
        catalog = LLMModelCatalog.all
        self.downloadedIDs = downloadedIDs
    }

    func url(for id: String) -> URL? {
        LLMModelCatalog.model(id: id).map {
            URL(fileURLWithPath: "/fake/\($0.fileName)")
        }
    }

    func isDownloaded(_ id: String) -> Bool {
        downloadedIDs.contains(id)
    }

    func downloadedModelIDs() -> [String] {
        catalog.filter { downloadedIDs.contains($0.id) }.map(\.id)
    }

    func download(
        _ id: String,
        progress _: @Sendable @escaping (Int64, Int64?) -> Void
    ) async throws {
        downloadCalledIDs.append(id)
        if downloadShouldFail {
            throw NSError(
                domain: "FakeDownload", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Download failed"]
            )
        }
        downloadedIDs.insert(id)
    }

    func delete(_ id: String) throws {
        downloadedIDs.remove(id)
    }
}

/// Fake model provider whose download suspends until explicitly released.
/// Used for one-at-a-time guard tests.
private final class BlockingModelProvider: ModelProviding,
    @unchecked Sendable
{
    let catalog: [LLMModel] = LLMModelCatalog.all
    var downloadedIDs: Set<String> = []

    private let enteredStream: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let releaseStream: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation

    var downloadCalledIDs: [String] = []

    init() {
        let (eStream, eCont) = AsyncStream<Void>.makeStream()
        enteredStream = eStream
        enteredContinuation = eCont
        let (rStream, rCont) = AsyncStream<Void>.makeStream()
        releaseStream = rStream
        releaseContinuation = rCont
    }

    func url(for id: String) -> URL? {
        LLMModelCatalog.model(id: id).map {
            URL(fileURLWithPath: "/fake/\($0.fileName)")
        }
    }

    func isDownloaded(_ id: String) -> Bool {
        downloadedIDs.contains(id)
    }

    func downloadedModelIDs() -> [String] {
        catalog.filter { downloadedIDs.contains($0.id) }.map(\.id)
    }

    func download(
        _ id: String,
        progress _: @Sendable @escaping (Int64, Int64?) -> Void
    ) async throws {
        downloadCalledIDs.append(id)
        enteredContinuation.yield()
        var iterator = releaseStream.makeAsyncIterator()
        _ = await iterator.next()
        downloadedIDs.insert(id)
    }

    func delete(_ id: String) throws {
        downloadedIDs.remove(id)
    }

    func waitUntilEntered() async {
        var iterator = enteredStream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() {
        releaseContinuation.yield()
    }
}

/// Fake hardware probe with configurable RAM and disk.
private struct MMFakeHardwareProbe: HardwareProbing {
    var physicalMemoryBytes: UInt64
    var diskBytes: Int64?

    init(
        physicalMemoryBytes: UInt64 = 32_000_000_000,
        diskBytes: Int64? = 100_000_000_000
    ) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.diskBytes = diskBytes
    }

    func availableDiskBytes(at _: URL) -> Int64? {
        diskBytes
    }
}

// MARK: - Helpers

private let model12B = "gemma-4-12b"
private let modelE2B = "gemma-4-e2b"

/// Groups the ModelManager and its fakes for test convenience.
private struct ManagerFixture {
    let mgr: ModelManager
    let models: MMFakeModelProvider
    let store: DataStore
}

private func makeStore() throws -> DataStore {
    try DataStore(storage: .inMemory)
}

@MainActor private func makeManager(
    store: DataStore? = nil,
    downloadedIDs: Set<String> = [],
    ram: UInt64 = 32_000_000_000,
    disk: Int64? = 100_000_000_000
) throws -> ManagerFixture {
    let dataStore = try store ?? makeStore()
    let models = MMFakeModelProvider(downloadedIDs: downloadedIDs)
    let hardware = MMFakeHardwareProbe(
        physicalMemoryBytes: ram, diskBytes: disk
    )
    let manager = ModelManager(
        store: dataStore, models: models, hardware: hardware
    )
    return ManagerFixture(mgr: manager, models: models, store: dataStore)
}

// MARK: - Active-model resolution + migration

@Suite("ModelManager active-model resolution")
struct ModelManagerResolutionTests {
    @Test("selected + downloaded resolves to that model")
    @MainActor func selectedAndDownloaded() async throws {
        let fix = try makeManager(downloadedIDs: [model12B])
        try await fix.store.updateSettings { settings in
            settings.selectedModelID = model12B
        }

        await fix.mgr.refresh()

        #expect(fix.mgr.activeModelID == model12B)
        #expect(fix.mgr.selectedModelID == model12B)
        #expect(fix.mgr.isModelAvailable == true)
        #expect(fix.mgr.activeModelURL() != nil)
    }

    @Test("empty selection falls back to first downloaded in catalog order")
    @MainActor func emptySelectionFallback() async throws {
        let fix = try makeManager(
            downloadedIDs: [model12B, modelE2B]
        )

        await fix.mgr.refresh()

        #expect(fix.mgr.activeModelID == model12B)
        #expect(fix.mgr.selectedModelID == model12B)
    }

    @Test("stale selection (non-downloaded) falls back to first downloaded")
    @MainActor func staleSelectionFallback() async throws {
        let store = try makeStore()
        try await store.updateSettings { settings in
            settings.selectedModelID = model12B
        }

        let fix = try makeManager(
            store: store, downloadedIDs: [modelE2B]
        )

        await fix.mgr.refresh()

        #expect(fix.mgr.activeModelID == modelE2B)
        #expect(fix.mgr.selectedModelID == modelE2B)

        let settings = try await store.settings()
        #expect(settings.selectedModelID == modelE2B)
    }

    @Test("no downloaded models -> nil active, not available")
    @MainActor func noDownloadedModels() async throws {
        let fix = try makeManager(downloadedIDs: [])

        await fix.mgr.refresh()

        #expect(fix.mgr.activeModelID == nil)
        #expect(fix.mgr.isModelAvailable == false)
        #expect(fix.mgr.activeModelURL() == nil)
    }

    @Test("existing-user migration: 12B downloaded, empty selection -> 12B persisted")
    @MainActor func existingUserMigration() async throws {
        let store = try makeStore()
        let fix = try makeManager(
            store: store, downloadedIDs: [model12B]
        )

        await fix.mgr.refresh()

        #expect(fix.mgr.activeModelID == model12B)
        #expect(fix.mgr.selectedModelID == model12B)

        let settings = try await store.settings()
        #expect(settings.selectedModelID == model12B)
    }

    @Test("selected model already correct: no redundant write-back")
    @MainActor func noRedundantWriteBack() async throws {
        let store = try makeStore()
        try await store.updateSettings { settings in
            settings.selectedModelID = model12B
        }

        let fix = try makeManager(
            store: store, downloadedIDs: [model12B]
        )

        await fix.mgr.refresh()

        #expect(fix.mgr.selectedModelID == model12B)
        let settings = try await store.settings()
        #expect(settings.selectedModelID == model12B)
    }

    @Test("refresh preserves in-flight download state")
    @MainActor func refreshPreservesInFlight() async throws {
        let fix = try makeManager(downloadedIDs: [])

        fix.mgr.downloads[modelE2B] = .downloading(fraction: 0.5)

        await fix.mgr.refresh()

        if case let .downloading(fraction) = fix.mgr.downloads[modelE2B] {
            #expect(fraction == 0.5)
        } else {
            Issue.record("Expected .downloading state to be preserved")
        }
    }
}

// MARK: - Auto-select on first download

@Suite("ModelManager auto-select on download")
struct ModelManagerAutoSelectTests {
    @Test("first download auto-selects when no valid selection")
    @MainActor func firstDownloadAutoSelects() async throws {
        let fix = try makeManager(downloadedIDs: [])

        await fix.mgr.refresh()
        #expect(fix.mgr.activeModelID == nil)

        await fix.mgr.downloadModel(id: modelE2B)

        #expect(fix.mgr.selectedModelID == modelE2B)
        #expect(fix.mgr.activeModelID == modelE2B)
        #expect(fix.mgr.downloads[modelE2B] == .downloaded)

        let settings = try await fix.store.settings()
        #expect(settings.selectedModelID == modelE2B)
    }

    @Test("download does not change selection when valid selection exists")
    @MainActor func downloadKeepsExistingSelection() async throws {
        let fix = try makeManager(downloadedIDs: [model12B])

        await fix.mgr.refresh()
        #expect(fix.mgr.selectedModelID == model12B)

        await fix.mgr.downloadModel(id: modelE2B)

        #expect(fix.mgr.selectedModelID == model12B)
        #expect(fix.mgr.activeModelID == model12B)
    }

    @Test("failed download does not auto-select")
    @MainActor func failedDownloadNoAutoSelect() async throws {
        let store = try makeStore()
        let models = MMFakeModelProvider(downloadedIDs: [])
        models.downloadShouldFail = true
        let hardware = MMFakeHardwareProbe()
        let mgr = ModelManager(
            store: store, models: models, hardware: hardware
        )

        await mgr.refresh()
        await mgr.downloadModel(id: modelE2B)

        #expect(mgr.selectedModelID == "")
        #expect(mgr.activeModelID == nil)

        if case .failed = mgr.downloads[modelE2B] {
            // expected
        } else {
            Issue.record("Expected .failed state after download error")
        }
    }
}

// MARK: - Delete -> fallback / clear

@Suite("ModelManager delete")
struct ModelManagerDeleteTests {
    @Test("delete selected model falls back to next downloaded")
    @MainActor func deleteFallsBackToNext() async throws {
        let fix = try makeManager(
            downloadedIDs: [model12B, modelE2B]
        )

        await fix.mgr.refresh()
        #expect(fix.mgr.selectedModelID == model12B)

        await fix.mgr.deleteModel(id: model12B)

        #expect(fix.mgr.selectedModelID == modelE2B)
        #expect(fix.mgr.activeModelID == modelE2B)
        #expect(fix.mgr.downloads[model12B] == .notDownloaded)

        let settings = try await fix.store.settings()
        #expect(settings.selectedModelID == modelE2B)
    }

    @Test("delete last model clears selection entirely")
    @MainActor func deleteLastClearsSelection() async throws {
        let fix = try makeManager(downloadedIDs: [modelE2B])

        await fix.mgr.refresh()
        #expect(fix.mgr.selectedModelID == modelE2B)

        await fix.mgr.deleteModel(id: modelE2B)

        #expect(fix.mgr.selectedModelID == "")
        #expect(fix.mgr.activeModelID == nil)
        #expect(fix.mgr.isModelAvailable == false)

        let settings = try await fix.store.settings()
        #expect(settings.selectedModelID == "")
    }

    @Test("delete non-selected model does not change selection")
    @MainActor func deleteNonSelectedKeepsSelection() async throws {
        let fix = try makeManager(
            downloadedIDs: [model12B, modelE2B]
        )

        await fix.mgr.refresh()
        #expect(fix.mgr.selectedModelID == model12B)

        await fix.mgr.deleteModel(id: modelE2B)

        #expect(fix.mgr.selectedModelID == model12B)
        #expect(fix.mgr.activeModelID == model12B)
    }
}

// MARK: - Select guard

@Suite("ModelManager select guard")
struct ModelManagerSelectGuardTests {
    @Test("selecting a non-downloaded model is rejected")
    @MainActor func selectNonDownloaded() async throws {
        let fix = try makeManager(downloadedIDs: [model12B])

        await fix.mgr.refresh()
        #expect(fix.mgr.selectedModelID == model12B)

        await fix.mgr.selectModel(id: modelE2B)

        #expect(fix.mgr.selectedModelID == model12B)
    }

    @Test("selecting a non-runnable model is rejected")
    @MainActor func selectNonRunnable() async throws {
        // 8 GB RAM: 12B requires 15 GB, so selectModel rejects it
        let fix = try makeManager(
            downloadedIDs: [model12B, modelE2B],
            ram: 8_000_000_000
        )

        await fix.mgr.refresh()

        // Force selection to E2B first (runnable at any RAM)
        await fix.mgr.selectModel(id: modelE2B)
        #expect(fix.mgr.selectedModelID == modelE2B)

        // Now try to select 12B (not runnable at 8 GB RAM)
        await fix.mgr.selectModel(id: model12B)

        // Should be rejected -- still E2B
        #expect(fix.mgr.selectedModelID == modelE2B)
    }

    @Test("selecting an unknown model id is rejected")
    @MainActor func selectUnknownID() async throws {
        let fix = try makeManager(downloadedIDs: [model12B])

        await fix.mgr.refresh()
        #expect(fix.mgr.selectedModelID == model12B)

        await fix.mgr.selectModel(id: "nonexistent-model")

        #expect(fix.mgr.selectedModelID == model12B)
    }

    @Test("selecting a valid downloaded runnable model succeeds")
    @MainActor func selectValid() async throws {
        let fix = try makeManager(
            downloadedIDs: [model12B, modelE2B]
        )

        await fix.mgr.refresh()
        #expect(fix.mgr.selectedModelID == model12B)

        await fix.mgr.selectModel(id: modelE2B)

        #expect(fix.mgr.selectedModelID == modelE2B)
        #expect(fix.mgr.activeModelID == modelE2B)

        let settings = try await fix.store.settings()
        #expect(settings.selectedModelID == modelE2B)
    }
}

// MARK: - Clear selected model

@Suite("ModelManager clearSelectedModel")
struct ModelManagerClearSelectedModelTests {
    @Test("clearSelectedModel resets in-memory and persisted selection")
    @MainActor func clearResetsSelection() async throws {
        let fix = try makeManager(downloadedIDs: [model12B, modelE2B])

        await fix.mgr.refresh()
        // Start with an explicit selection
        await fix.mgr.selectModel(id: modelE2B)
        #expect(fix.mgr.selectedModelID == modelE2B)

        await fix.mgr.clearSelectedModel()

        // In-memory should be empty
        #expect(fix.mgr.selectedModelID == "")
        // Persisted should be empty
        let settings = try await fix.store.settings()
        #expect(settings.selectedModelID == "")
        // activeModelID falls back to first downloaded in catalog order
        #expect(fix.mgr.activeModelID == model12B)
    }

    @Test("clearSelectedModel when already empty is a no-op")
    @MainActor func clearWhenAlreadyEmpty() async throws {
        let fix = try makeManager(downloadedIDs: [])

        await fix.mgr.refresh()
        #expect(fix.mgr.selectedModelID == "")

        await fix.mgr.clearSelectedModel()

        #expect(fix.mgr.selectedModelID == "")
        let settings = try await fix.store.settings()
        #expect(settings.selectedModelID == "")
    }
}

// MARK: - One-at-a-time download guard

@Suite("ModelManager one-at-a-time download")
struct ModelManagerOneAtATimeTests {
    @Test("second download is blocked while first is in flight")
    @MainActor func secondDownloadBlocked() async throws {
        let store = try makeStore()
        let models = BlockingModelProvider()
        let hardware = MMFakeHardwareProbe()
        let mgr = ModelManager(
            store: store, models: models, hardware: hardware
        )

        for model in models.catalog {
            mgr.downloads[model.id] = .notDownloaded
        }

        let task1 = Task { @MainActor in
            await mgr.downloadModel(id: modelE2B)
        }

        await models.waitUntilEntered()

        if case .downloading = mgr.downloads[modelE2B] {
            // expected
        } else {
            Issue.record("Expected E2B to be in .downloading state")
        }

        // Try to start second download -- should be blocked
        await mgr.downloadModel(id: model12B)

        #expect(models.downloadCalledIDs.count == 1)
        #expect(models.downloadCalledIDs.first == modelE2B)

        models.release()
        await task1.value

        #expect(mgr.downloads[modelE2B] == .downloaded)
    }

    @Test("download blocked for non-runnable model")
    @MainActor func downloadBlockedNotRunnable() async throws {
        let fix = try makeManager(
            downloadedIDs: [], ram: 8_000_000_000
        )

        await fix.mgr.refresh()
        await fix.mgr.downloadModel(id: model12B)

        #expect(fix.models.downloadCalledIDs.isEmpty)
        #expect(fix.mgr.downloads[model12B] == .notDownloaded)
    }

    @Test("download blocked for insufficient disk")
    @MainActor func downloadBlockedInsufficientDisk() async throws {
        let fix = try makeManager(
            downloadedIDs: [], disk: 1_000_000_000
        )

        await fix.mgr.refresh()
        await fix.mgr.downloadModel(id: modelE2B)

        #expect(fix.models.downloadCalledIDs.isEmpty)
    }
}

// MARK: - modelChoices matrix

@Suite("ModelManager modelChoices")
struct ModelManagerModelChoicesTests {
    @Test("32 GB RAM, plenty of disk, 12B downloaded+selected")
    @MainActor func fullSetup32GB() async throws {
        let fix = try makeManager(downloadedIDs: [model12B])

        await fix.mgr.refresh()

        let choices = fix.mgr.modelChoices()
        #expect(choices.count == LLMModelCatalog.all.count)

        let row12B = choices.first { $0.id == model12B }
        #expect(row12B != nil)
        #expect(row12B?.runnable == true)
        #expect(row12B?.isDownloaded == true)
        #expect(row12B?.isSelected == true)
        #expect(row12B?.isRecommended == true)
        #expect(row12B?.hasEnoughDiskToDownload == true)
        #expect(row12B?.blockedReason == nil)
        #expect(row12B?.downloadState == .downloaded)

        let rowE2B = choices.first { $0.id == modelE2B }
        #expect(rowE2B != nil)
        #expect(rowE2B?.runnable == true)
        #expect(rowE2B?.isDownloaded == false)
        #expect(rowE2B?.isSelected == false)
        #expect(rowE2B?.isRecommended == false)
        #expect(rowE2B?.blockedReason == nil)
    }

    @Test("8 GB RAM: 12B not runnable, E2B recommended")
    @MainActor func lowRAM() async throws {
        let fix = try makeManager(
            downloadedIDs: [modelE2B], ram: 8_000_000_000
        )

        await fix.mgr.refresh()

        let choices = fix.mgr.modelChoices()

        let row12B = choices.first { $0.id == model12B }
        #expect(row12B?.runnable == false)
        #expect(row12B?.blockedReason == .cannotRun)
        #expect(row12B?.isRecommended == false)

        let rowE2B = choices.first { $0.id == modelE2B }
        #expect(rowE2B?.runnable == true)
        #expect(rowE2B?.isRecommended == true)
        #expect(rowE2B?.blockedReason == nil)
    }

    @Test("insufficient disk: not-downloaded model blocked")
    @MainActor func insufficientDisk() async throws {
        let fix = try makeManager(
            downloadedIDs: [], disk: 1_000_000_000
        )

        await fix.mgr.refresh()

        let choices = fix.mgr.modelChoices()

        let rowE2B = choices.first { $0.id == modelE2B }
        #expect(rowE2B?.hasEnoughDiskToDownload == false)
        #expect(rowE2B?.blockedReason == .insufficientDisk)

        let row12B = choices.first { $0.id == model12B }
        #expect(row12B?.hasEnoughDiskToDownload == false)
        #expect(row12B?.blockedReason == .insufficientDisk)
    }

    @Test("downloaded model is never blocked by disk")
    @MainActor func downloadedNotBlockedByDisk() async throws {
        let fix = try makeManager(
            downloadedIDs: [modelE2B], disk: 1_000_000_000
        )

        await fix.mgr.refresh()

        let choices = fix.mgr.modelChoices()
        let rowE2B = choices.first { $0.id == modelE2B }
        #expect(rowE2B?.isDownloaded == true)
        #expect(rowE2B?.blockedReason == nil)
    }

    @Test("descriptions come from ModelPolicy")
    @MainActor func descriptionsFromPolicy() async throws {
        let fix = try makeManager()

        await fix.mgr.refresh()

        let choices = fix.mgr.modelChoices()
        let row12B = choices.first { $0.id == model12B }
        #expect(row12B?.description == ModelPolicy.description(id: model12B))
        #expect(row12B?.description.contains("7 GB") == true)

        let rowE2B = choices.first { $0.id == modelE2B }
        #expect(rowE2B?.description == ModelPolicy.description(id: modelE2B))
    }

    @Test("no models downloaded: no row is selected")
    @MainActor func noModelsNoneSelected() async throws {
        let fix = try makeManager(downloadedIDs: [])

        await fix.mgr.refresh()

        let choices = fix.mgr.modelChoices()
        let selectedCount = choices.filter(\.isSelected).count
        #expect(selectedCount == 0)
    }
}

// MARK: - Intelligence integration

@Suite("ModelManager Intelligence integration")
struct ModelManagerIntelligenceIntegrationTests {
    /// Fake LLM runner that records the model URL.
    private final class RecordingLLMRunner: LLMRunning,
        @unchecked Sendable
    {
        var sessionCount = 0
        var lastModelURL: URL?
        let session: RecordingSession

        init() {
            session = RecordingSession()
        }

        func withSession<T: Sendable>(
            model: URL,
            config _: EngineConfig,
            _ body: @Sendable (any LLMSession) async throws -> T
        ) async throws -> T {
            sessionCount += 1
            lastModelURL = model
            return try await body(session)
        }
    }

    private final class RecordingSession: LLMSession,
        @unchecked Sendable
    {
        private var generateCallIndex = 0
        var generateResponses: [String] = []
        var streamingTokens: [[String]] = []
        private var streamingCallIndex = 0

        func countTokens(messages _: [LLMMessage]) async throws -> Int {
            100
        }

        func reconfigure(contextSize _: Int) async throws {}

        func generate(
            messages _: [LLMMessage], options _: GenerationOptions
        ) async throws -> String {
            let idx = generateCallIndex
            generateCallIndex += 1
            guard idx < generateResponses.count else { return "" }
            return generateResponses[idx]
        }

        func generateStreaming(
            messages _: [LLMMessage], options _: GenerationOptions
        ) async -> AsyncThrowingStream<StreamEvent, Error> {
            let idx = streamingCallIndex
            streamingCallIndex += 1
            let tokens: [String] = if idx < streamingTokens.count {
                streamingTokens[idx]
            } else {
                []
            }
            let doneText = tokens.joined()
            let result = makeStreamResult(text: doneText)
            let events: [StreamEvent] =
                tokens.map { .token($0) } + [.done(result)]
            var iterator = events.makeIterator()
            return AsyncThrowingStream { iterator.next() }
        }
    }

    private static func makeStreamResult(
        text: String
    ) -> GenerationResult {
        let json: [String: Any] = [
            "text": text,
            "promptTokenCount": 0,
            "generatedTokenCount": 1,
            "cachedPromptTokenCount": 0,
            "finishReason": ["endOfTurn": [String: Any]()],
            "promptEvalDuration": 0.0,
            "generationDuration": 0.0,
            "totalDuration": 0.0,
            "renderedPrompt": "",
            "rawText": text
        ]
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: json)
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(
            GenerationResult.self, from: data
        )
    }

    private static func makeTranscriptResult() -> TranscriptResult {
        TranscriptResult(
            transcriptionMethodId: "v1",
            language: "en",
            speakerCount: 2,
            segments: [
                TranscriptSegment(
                    speakerID: 0, speakerLabel: "Speaker 0",
                    startTime: 0, endTime: 5,
                    text: "Hello everyone", confidence: 0.9,
                    noSpeechProbability: 0.1, words: nil
                ),
                TranscriptSegment(
                    speakerID: 1, speakerLabel: "Speaker 1",
                    startTime: 5, endTime: 10,
                    text: "Hi there", confidence: 0.85,
                    noSpeechProbability: 0.15, words: nil
                )
            ],
            speakerEmbeddings: [:],
            processingDuration: 3.0
        )
    }

    @Test("Intelligence passes active model URL to LLM runner")
    @MainActor func passesActiveModelURL() async throws {
        let fix = try makeManager(downloadedIDs: [model12B])
        await fix.mgr.refresh()

        let runner = RecordingLLMRunner()
        runner.session.generateResponses = ["0 | Alice |"]
        runner.session.streamingTokens = [["Summary"]]

        let intel = Intelligence(
            store: fix.store, llm: runner, modelManager: fix.mgr,
            settings: { AISettings(enabled: true) }
        )

        let meetingID = try await fix.store.createMeeting(title: "Test")
        let result = Self.makeTranscriptResult()
        let txID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(txID, for: meetingID)

        await intel.runAutoEnhancements(meetingID: meetingID)

        #expect(runner.sessionCount == 1)

        let expectedURL = fix.models.url(for: model12B)
        #expect(runner.lastModelURL == expectedURL)
        #expect(expectedURL != nil)
    }

    @Test("Intelligence no-ops when no active model")
    @MainActor func noOpsWhenNoModel() async throws {
        let fix = try makeManager(downloadedIDs: [])
        await fix.mgr.refresh()

        let runner = RecordingLLMRunner()
        let intel = Intelligence(
            store: fix.store, llm: runner, modelManager: fix.mgr,
            settings: { AISettings(enabled: true) }
        )

        let meetingID = try await fix.store.createMeeting(title: "Test")
        let result = Self.makeTranscriptResult()
        let txID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(txID, for: meetingID)

        await intel.runAutoEnhancements(meetingID: meetingID)

        #expect(runner.sessionCount == 0)
        #expect(intel.jobs[meetingID] == nil)
    }

    @Test("Intelligence uses correct model after selection change")
    @MainActor func usesModelAfterSelectionChange() async throws {
        let fix = try makeManager(
            downloadedIDs: [model12B, modelE2B]
        )
        await fix.mgr.refresh()
        #expect(fix.mgr.activeModelID == model12B)

        await fix.mgr.selectModel(id: modelE2B)
        #expect(fix.mgr.activeModelID == modelE2B)

        let runner = RecordingLLMRunner()
        runner.session.generateResponses = ["0 | Alice |"]
        runner.session.streamingTokens = [["Summary"]]

        let intel = Intelligence(
            store: fix.store, llm: runner, modelManager: fix.mgr,
            settings: { AISettings(enabled: true) }
        )

        let meetingID = try await fix.store.createMeeting(title: "Test")
        let result = Self.makeTranscriptResult()
        let txID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(txID, for: meetingID)

        await intel.runAutoEnhancements(meetingID: meetingID)

        let expectedURL = fix.models.url(for: modelE2B)
        #expect(runner.lastModelURL == expectedURL)
    }
}

// MARK: - LastFraction tests

@Suite("LastFraction download throttle")
struct LastFractionTests {
    @Test("first fraction is always reported")
    func firstFractionReported() {
        let tracker = LastFraction()
        #expect(tracker.shouldUpdate(to: 0.0) == true)
    }

    @Test("small increment is suppressed")
    func smallIncrementSuppressed() {
        let tracker = LastFraction()
        _ = tracker.shouldUpdate(to: 0.0)
        #expect(tracker.shouldUpdate(to: 0.005) == false)
    }

    @Test("1% increment is reported")
    func onePercentReported() {
        let tracker = LastFraction()
        _ = tracker.shouldUpdate(to: 0.0)
        #expect(tracker.shouldUpdate(to: 0.01) == true)
    }

    @Test("100% is always reported")
    func hundredPercentReported() {
        let tracker = LastFraction()
        _ = tracker.shouldUpdate(to: 0.99)
        #expect(tracker.shouldUpdate(to: 1.0) == true)
    }

    @Test("nil after non-nil is reported")
    func nilAfterNonNil() {
        let tracker = LastFraction()
        _ = tracker.shouldUpdate(to: 0.5)
        #expect(tracker.shouldUpdate(to: nil) == true)
    }

    @Test("nil when no previous value is suppressed")
    func nilFirstIsSuppressed() {
        let tracker = LastFraction()
        #expect(tracker.shouldUpdate(to: nil) == false)
    }
}
