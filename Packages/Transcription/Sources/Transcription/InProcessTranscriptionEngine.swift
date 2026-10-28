import Foundation
import os.log
import SpeakerKit
import Synchronization
import WhisperKit

/// In-process implementation of `TranscriptionEngine`.
///
/// Refactored from `ArgMaxProcessor` in the experiment. Runs WhisperKit (STT)
/// and SpeakerKit (diarization) in the calling process. Used by the CLI harness
/// and as the fallback when no XPC host is present.
public actor InProcessTranscriptionEngine: TranscriptionEngine {
    private static let log = Logger(
        subsystem: "net.scosman.biscotti",
        category: "TranscriberEngine"
    )

    private let method: TranscriptionMethod
    private let resolvedSettings: ResolvedMethodSettings
    private let statusMachine: ModelStatusMachine
    private let diskSpaceChecker: DiskSpaceChecking
    private var whisperKit: WhisperKit?
    private var speakerKit: SpeakerKit?
    /// Told when a model load starts and ends.
    private var modelLoadObserver: (@Sendable (Bool) -> Void)?

    /// Estimated bytes required for model download (STT + diarization).
    /// Sized per model variant (on-disk size + headroom) + SpeakerKit ~33 MB.
    /// We use a conservative estimate based on the model name.
    private var estimatedDownloadBytes: Int64 {
        if resolvedSettings.sttModel.contains("1307MB") {
            1_400_000_000 // ~1.3 GB + headroom
        } else if resolvedSettings.sttModel.contains("1049MB") {
            1_150_000_000
        } else if resolvedSettings.sttModel.contains("954MB") {
            1_050_000_000
        } else if resolvedSettings.sttModel.contains("626MB") {
            750_000_000 // ~626 MB + headroom + SpeakerKit ~33 MB
        } else {
            3_300_000_000 // full-precision ~3.1 GB + headroom
        }
    }

    public init(
        method: TranscriptionMethod = .current
    ) {
        self.method = method
        resolvedSettings = MethodResolver.resolve(method)
        statusMachine = ModelStatusMachine(initial: .needsDownload)
        diskSpaceChecker = SystemDiskSpaceChecker()
    }

    /// Internal init for testing with an injected disk-space checker and,
    /// optionally, a Whisper model already set up.
    init(
        method: TranscriptionMethod = .current,
        diskSpaceChecker: DiskSpaceChecking,
        whisperKit: sending WhisperKit? = nil
    ) {
        self.method = method
        resolvedSettings = MethodResolver.resolve(method)
        statusMachine = ModelStatusMachine(initial: .needsDownload)
        self.diskSpaceChecker = diskSpaceChecker
        self.whisperKit = whisperKit
    }

    // MARK: - TranscriptionEngine

    public func ensureModelsDownloaded(
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        Self.log.debug("ensureModelsDownloaded: begin")
        try await checkDiskSpace()
        await statusMachine.transition(to: .downloading(progress: 0.0))

        // No numeric progress: the SDK's only progress signal is file-count
        // weighted (one ~3 GB file counts the same as a tiny config), which is
        // misleading, so we report a status message per stage instead.
        try await downloadWhisperKitIfNeeded(status: status)
        try await downloadSpeakerKitIfNeeded(status: status)
        Self.log.debug("ensureModelsDownloaded: complete")
    }

    public func processAudio(
        micPath: String,
        systemPath: String,
        customVocabulary: [String]
    ) async throws -> TranscriptResult {
        Self.log.debug("processAudio: begin")
        let startTime = CFAbsoluteTimeGetCurrent()

        let mergeResult = try loadAndMergeAudio(
            micPath: micPath, systemPath: systemPath
        )

        await statusMachine.transition(to: .running)

        let sttResults = try await runSTT(
            audioArray: mergeResult.samples, customVocabulary: customVocabulary
        )

        if resolvedSettings.sequentialLoading { await unloadWhisperKit() }

        // A pass cancelled during STT ends here, before diarization starts.
        do {
            try Task.checkCancellation()
        } catch {
            await statusMachine.transition(to: .ready)
            throw TranscriptionError.cancelled
        }

        let diarization = try await runDiarization(audioArray: mergeResult.samples)

        if resolvedSettings.sequentialLoading { await unloadSpeakerKit() }

        let result = assembleResult(
            sttResults: sttResults, diarization: diarization,
            audioDuration: mergeResult.duration, startTime: startTime
        )

        await statusMachine.transition(to: .ready)
        Self.log.debug("processAudio: complete")
        return result
    }

    /// Calls `observer` when a model load starts (true) and ends (false);
    /// nil stops it.
    public func observeModelLoads(_ observer: (@Sendable (Bool) -> Void)?) {
        modelLoadObserver = observer
    }

    public func unloadModels() async {
        Self.log.debug("unloadModels: begin")
        await unloadWhisperKit()
        await unloadSpeakerKit()
        await statusMachine.transition(to: .needsDownload)
        Self.log.debug("unloadModels: complete")
    }

    public func modelsPresent() async -> Bool {
        Self.log.debug("modelsPresent: checking disk")
        let sttPresent = Self.whisperKitModelsPresent(
            repo: resolvedSettings.sttModelRepo,
            model: resolvedSettings.sttModel
        )
        let speakerPresent = Self.speakerKitModelsPresent()
        Self.log.debug("modelsPresent: stt=\(sttPresent), speaker=\(speakerPresent)")
        return sttPresent && speakerPresent
    }

    public func status() async -> ModelStatus {
        await statusMachine.current
    }
}

// MARK: - Sharing Whisper with the live session

/// A loaded `WhisperKit` handed from the code that loaded it to a live decoder.
///
/// `WhisperKit` is not `Sendable`, so it cannot leave the engine's actor on its
/// own. The two sides never use it at the same time: `EngineHost` runs no final
/// pass while a live session decodes with the engine's model, and waits for the
/// last live decode to return before it runs one.
package struct LoadedWhisperKit: @unchecked Sendable {
    package let whisperKit: WhisperKit
}

package extension InProcessTranscriptionEngine {
    /// The Whisper model folder name the final pass uses.
    nonisolated var whisperModelName: String {
        resolvedSettings.sttModel
    }

    /// The final pass's Whisper model, loaded if it is not, for a live session
    /// that uses the same model. Never downloads: unless the model is fully
    /// loaded, it must be in the model cache with a tokenizer that loads from
    /// there, as for `loadLocalWhisperKit`, also when the final pass's
    /// download step left it unloaded. The final pass then reuses this load.
    /// - Throws: `TranscriptionError.needsDownload` when it is not.
    func loadedWhisperKit(downloadBase: URL = ModelStorage.downloadBase) async throws -> LoadedWhisperKit {
        try await ensureWhisperKitLoaded(localOnlyFrom: downloadBase)
        guard let whisperKit else {
            throw TranscriptionError.modelLoadFailed("WhisperKit is nil after loading")
        }
        return LoadedWhisperKit(whisperKit: whisperKit)
    }

    /// Loads a downloaded Whisper model from the model cache, in the layout the
    /// final pass's download uses: `models/argmaxinc/whisperkit-coreml/<model>`
    /// with its tokenizer under `models/openai/`. Never downloads: the
    /// tokenizer must load from the cache first, because WhisperKit fetches
    /// one from the Hub when its local files fail to load.
    /// - Throws: `TranscriptionError.needsDownload` when the model is not on
    ///   disk or its tokenizer does not load, so the download repairs it.
    static func loadLocalWhisperKit(model: String, downloadBase: URL = ModelStorage.downloadBase) async throws -> LoadedWhisperKit {
        let repo = MethodResolver.defaultRepo
        let folder = try await localModelFolder(model: model, repo: repo, downloadBase: downloadBase)
        do {
            let whisperKit = try await WhisperKit(WhisperKitConfig(
                model: model,
                downloadBase: downloadBase,
                modelRepo: repo,
                modelFolder: folder.path,
                verbose: false,
                prewarm: false,
                load: true,
                download: false
            ))
            return LoadedWhisperKit(whisperKit: whisperKit)
        } catch {
            throw TranscriptionError.modelLoadFailed("WhisperKit init failed for \(model): \(error.localizedDescription)")
        }
    }

    /// The model's folder in the cache, once the model is there and its
    /// tokenizer loads from the cache alone.
    /// - Throws: `TranscriptionError.needsDownload` otherwise.
    private static func localModelFolder(model: String, repo: String, downloadBase: URL) async throws -> URL {
        let folder = downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent(model, isDirectory: true)
        guard directoryContainsMLModel(folder),
              await WhisperModelFiles.tokenizerLoadsLocally(model: model, downloadBase: downloadBase)
        else {
            throw TranscriptionError.needsDownload
        }
        return folder
    }
}

/// Set once, from any thread.
private final class CancellationFlag: Sendable {
    private let value = Atomic(false)

    var isSet: Bool {
        value.load(ordering: .acquiring)
    }

    func set() {
        value.store(true, ordering: .releasing)
    }
}

// MARK: - Read-only disk checks

extension InProcessTranscriptionEngine {
    /// Check if WhisperKit model files are present on disk at the expected
    /// download location. Does NOT load, compile, or download anything.
    ///
    /// The Hub client writes models to:
    ///   `downloadBase/models/<repo>/<model>/`
    /// We check for at least one `.mlmodelc` directory inside that folder.
    static func whisperKitModelsPresent(
        repo: String,
        model: String
    ) -> Bool {
        let modelDir = ModelStorage.modelsDirectory
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent(model, isDirectory: true)
        return directoryContainsMLModel(modelDir)
    }

    /// Check if SpeakerKit (Pyannote) model files are present on disk.
    ///
    /// SpeakerKit downloads to:
    ///   `downloadBase/models/argmaxinc/speakerkit-coreml/`
    /// We check for at least one `.mlmodelc` directory inside that folder
    /// (or its subdirectories, since SpeakerKit nests models).
    static func speakerKitModelsPresent() -> Bool {
        let speakerDir = ModelStorage.modelsDirectory
            .appendingPathComponent("argmaxinc/speakerkit-coreml", isDirectory: true)
        return directoryContainsMLModel(speakerDir)
    }

    /// Returns `true` if `directory` (or any immediate subdirectory) contains
    /// at least one `.mlmodelc` bundle.
    static func directoryContainsMLModel(_ directory: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return false }
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let url as URL in enumerator where url.pathExtension == "mlmodelc" {
            return true
        }
        return false
    }
}

// MARK: - Processing helpers

private extension InProcessTranscriptionEngine {
    func loadAndMergeAudio(
        micPath: String, systemPath: String
    ) throws -> AudioLoading.MergeResult {
        try AudioLoading.loadAndMerge(micPath: micPath, systemPath: systemPath)
    }

    func runSTT(
        audioArray: [Float], customVocabulary: [String]
    ) async throws -> [TranscriptionResult] {
        do {
            try await ensureWhisperKitLoaded()

            var decodingOptions = resolvedSettings.decodingOptions

            if let promptText = VocabularyFormatter.formatPrompt(from: customVocabulary) {
                if let tokenizer = whisperKit?.tokenizer {
                    decodingOptions.promptTokens = tokenizer.encode(text: promptText)
                }
            }

            guard let whisper = whisperKit else {
                throw TranscriptionError.modelLoadFailed("WhisperKit is nil after loading")
            }
            // WhisperKit stops between windows when its callback returns false.
            // The flag is set by the cancellation handler, so it does not
            // matter which task WhisperKit calls the callback on.
            let stop = CancellationFlag()
            return try await withTaskCancellationHandler {
                try await whisper.transcribe(
                    audioArray: audioArray,
                    decodeOptions: decodingOptions,
                    callback: { _ in stop.isSet ? false : nil }
                )
            } onCancel: {
                stop.set()
            }
        } catch is CancellationError {
            await statusMachine.transition(to: .ready)
            throw TranscriptionError.cancelled
        } catch let error as TranscriptionError {
            await statusMachine.transition(to: .error(error))
            throw error
        } catch {
            let wrappedError = TranscriptionError.transcriptionFailed(error.localizedDescription)
            await statusMachine.transition(to: .error(wrappedError))
            throw wrappedError
        }
    }

    func runDiarization(audioArray: [Float]) async throws -> DiarizationResult {
        do {
            try await ensureSpeakerKitLoaded()

            guard let speaker = speakerKit else {
                throw TranscriptionError.modelLoadFailed("SpeakerKit is nil after loading")
            }
            return try await speaker.diarize(
                audioArray: audioArray,
                options: DiarizationSettings.options
            )
        } catch let error as TranscriptionError {
            await statusMachine.transition(to: .error(error))
            throw error
        } catch {
            let wrappedError = TranscriptionError.diarizationFailed(error.localizedDescription)
            await statusMachine.transition(to: .error(wrappedError))
            throw wrappedError
        }
    }

    func assembleResult(
        sttResults: [TranscriptionResult],
        diarization: DiarizationResult,
        audioDuration: TimeInterval,
        startTime: CFAbsoluteTime
    ) -> TranscriptResult {
        let strategy: SpeakerInfoStrategy = switch resolvedSettings.diarizationStrategy {
        case .subsegment: .subsegment
        case .segment: .segment
        }

        let speakerSegmentGroups = diarization.addSpeakerInfo(
            to: sttResults,
            strategy: strategy
        )

        let language = sttResults.first?.language ?? "unknown"
        let segments = SegmentBuilder.buildSegments(from: speakerSegmentGroups)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let spans = SpeakerDurations.spans(from: diarization)

        let rawResult = TranscriptResult(
            transcriptionMethodId: method.id,
            language: language,
            speakerCount: diarization.speakerCount,
            segments: segments,
            embeddingSets: EmbeddingSetBuilder.build(from: diarization),
            speakerSpeechDurations: SpeakerDurations.compute(spans),
            processingDuration: elapsed
        )

        return TranscriptSanitizer.sanitize(rawResult, audioDuration: audioDuration)
    }
}

// MARK: - Model lifecycle helpers

private extension InProcessTranscriptionEngine {
    /// - Parameter downloadBase: Loads only from this model cache, never
    ///   downloading; nil lets WhisperKit download a missing model.
    func ensureWhisperKitLoaded(localOnlyFrom downloadBase: URL? = nil) async throws {
        modelLoadObserver?(true)
        defer { modelLoadObserver?(false) }
        // Loading a model that is not fully loaded, also one the download step
        // left unloaded, loads its tokenizer, which WhisperKit fetches from the
        // Hub when the cache's does not load: check the cache first.
        var localFolder: URL?
        if let downloadBase, whisperKit?.modelState != .loaded {
            localFolder = try await Self.localModelFolder(
                model: resolvedSettings.sttModel, repo: resolvedSettings.sttModelRepo, downloadBase: downloadBase
            )
        }
        if whisperKit == nil {
            Self.log.info("WhisperKit: loading model (first init)")
            await statusMachine.transition(to: .loading)
            do {
                whisperKit = try await WhisperKit(makeWhisperConfig(
                    load: true,
                    download: localFolder == nil,
                    modelFolder: localFolder,
                    downloadBase: downloadBase ?? ModelStorage.downloadBase
                ))
            } catch {
                let wrappedError = TranscriptionError.modelLoadFailed(
                    "WhisperKit init failed: \(error.localizedDescription)"
                )
                await statusMachine.transition(to: .error(wrappedError))
                throw wrappedError
            }
            Self.log.info("WhisperKit: model loaded")
            await statusMachine.transition(to: .ready)
        } else {
            Self.log.debug("WhisperKit: reloading existing model")
            try await whisperKit?.loadModels()
        }
    }

    func ensureSpeakerKitLoaded() async throws {
        modelLoadObserver?(true)
        defer { modelLoadObserver?(false) }
        if speakerKit == nil {
            Self.log.info("SpeakerKit: loading model (first init)")
            do {
                speakerKit = try await SpeakerKit(
                    makeSpeakerConfig(download: true, load: false)
                )
            } catch {
                let wrappedError = TranscriptionError.modelLoadFailed(
                    "SpeakerKit init failed: \(error.localizedDescription)"
                )
                await statusMachine.transition(to: .error(wrappedError))
                throw wrappedError
            }
            Self.log.info("SpeakerKit: model loaded")
        } else {
            Self.log.debug("SpeakerKit: reloading existing model")
            try await speakerKit?.ensureModelsLoaded()
        }
    }

    func unloadWhisperKit() async {
        await whisperKit?.unloadModels()
        whisperKit = nil
    }

    func unloadSpeakerKit() async {
        await speakerKit?.unloadModels()
        speakerKit = nil
    }
}

// MARK: - Download helpers

private extension InProcessTranscriptionEngine {
    func checkDiskSpace() async throws {
        do {
            try diskSpaceChecker.checkAvailableSpace(requiredBytes: estimatedDownloadBytes)
        } catch let error as TranscriptionError {
            await statusMachine.transition(to: .error(error))
            throw error
        } catch {
            let wrappedError = TranscriptionError.insufficientDisk(
                requiredBytes: estimatedDownloadBytes,
                availableBytes: 0
            )
            await statusMachine.transition(to: .error(wrappedError))
            throw wrappedError
        }
    }

    func downloadWhisperKitIfNeeded(status: @escaping @Sendable (String) -> Void) async throws {
        guard whisperKit == nil else { return }
        status("Downloading speech-to-text model")
        do {
            whisperKit = try await WhisperKit(makeWhisperConfig(load: false, download: true))
        } catch {
            let wrappedError = TranscriptionError.downloadFailed(
                "WhisperKit download failed: \(error.localizedDescription)"
            )
            await statusMachine.transition(to: .error(wrappedError))
            throw wrappedError
        }
    }

    func downloadSpeakerKitIfNeeded(status: @escaping @Sendable (String) -> Void) async throws {
        guard speakerKit == nil else { return }
        status("Downloading speaker ID model")
        do {
            speakerKit = try await SpeakerKit(makeSpeakerConfig(download: true, load: false))
        } catch {
            let wrappedError = TranscriptionError.downloadFailed(
                "SpeakerKit download failed: \(error.localizedDescription)"
            )
            await statusMachine.transition(to: .error(wrappedError))
            throw wrappedError
        }
    }

    /// Build a WhisperKit configuration anchored at the shared cache location.
    func makeWhisperConfig(load: Bool, download: Bool, modelFolder: URL? = nil, downloadBase: URL = ModelStorage.downloadBase) -> WhisperKitConfig {
        WhisperKitConfig(
            model: resolvedSettings.sttModel,
            downloadBase: downloadBase,
            modelRepo: resolvedSettings.sttModelRepo,
            modelFolder: modelFolder?.path,
            verbose: false,
            load: load,
            download: download
        )
    }

    /// Build a SpeakerKit (Pyannote) configuration anchored at the shared cache.
    func makeSpeakerConfig(download: Bool, load: Bool) -> PyannoteConfig {
        SpeakerKitConfigFactory.make(download: download, load: load)
    }
}
