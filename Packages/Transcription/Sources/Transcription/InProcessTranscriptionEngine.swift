import Foundation
import SpeakerKit
import WhisperKit

/// In-process implementation of `TranscriptionEngine`.
///
/// Refactored from `ArgMaxProcessor` in the experiment. Runs WhisperKit (STT)
/// and SpeakerKit (diarization) in the calling process. Used by the CLI harness
/// and as the fallback when no XPC host is present.
public actor InProcessTranscriptionEngine: TranscriptionEngine {
    private let method: TranscriptionMethod
    private let resolvedSettings: ResolvedMethodSettings
    private let statusMachine: ModelStatusMachine
    private let diskSpaceChecker: DiskSpaceChecking
    private var whisperKit: WhisperKit?
    private var speakerKit: SpeakerKit?

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

    /// Internal init for testing with an injected disk-space checker.
    init(
        method: TranscriptionMethod = .current,
        diskSpaceChecker: DiskSpaceChecking
    ) {
        self.method = method
        resolvedSettings = MethodResolver.resolve(method)
        statusMachine = ModelStatusMachine(initial: .needsDownload)
        self.diskSpaceChecker = diskSpaceChecker
    }

    // MARK: - TranscriptionEngine

    public func ensureModelsDownloaded(
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        try await checkDiskSpace()
        await statusMachine.transition(to: .downloading(progress: 0.0))

        // No numeric progress: the SDK's only progress signal is file-count
        // weighted (one ~3 GB file counts the same as a tiny config), which is
        // misleading, so we report a status message per stage instead.
        try await downloadWhisperKitIfNeeded(status: status)
        try await downloadSpeakerKitIfNeeded(status: status)
    }

    public func processAudio(
        micPath: String,
        systemPath: String,
        customVocabulary: [String]
    ) async throws -> TranscriptResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        let mergeResult = try loadAndMergeAudio(
            micPath: micPath, systemPath: systemPath
        )

        await statusMachine.transition(to: .running)

        let sttResults = try await runSTT(
            audioArray: mergeResult.samples, customVocabulary: customVocabulary
        )

        if resolvedSettings.sequentialLoading { await unloadWhisperKit() }

        let diarization = try await runDiarization(audioArray: mergeResult.samples)

        if resolvedSettings.sequentialLoading { await unloadSpeakerKit() }

        let result = assembleResult(
            sttResults: sttResults, diarization: diarization,
            audioDuration: mergeResult.duration, startTime: startTime
        )

        await statusMachine.transition(to: .ready)
        return result
    }

    public func unloadModels() async {
        await unloadWhisperKit()
        await unloadSpeakerKit()
        await statusMachine.transition(to: .needsDownload)
    }

    public func status() async -> ModelStatus {
        await statusMachine.current
    }
}

// MARK: - Processing helpers

private extension InProcessTranscriptionEngine {
    func loadAndMergeAudio(
        micPath: String, systemPath: String
    ) throws -> MergeResult {
        let micSamples = try loadAudioSamples(fromPath: micPath)
        let systemSamples = try loadAudioSamples(fromPath: systemPath)
        return try AudioMerger.merge(mic: micSamples, system: systemSamples)
    }

    func runSTT(
        audioArray: [Float], customVocabulary: [String]
    ) async throws -> [TranscriptionResult] {
        do {
            try await ensureWhisperKitLoaded()

            var decodingOptions = DecodingOptions(
                wordTimestamps: resolvedSettings.enableWordTimestamps
            )

            if let promptText = VocabularyFormatter.formatPrompt(from: customVocabulary) {
                if let tokenizer = whisperKit?.tokenizer {
                    decodingOptions.promptTokens = tokenizer.encode(text: promptText)
                }
            }

            guard let whisper = whisperKit else {
                throw TranscriptionError.modelLoadFailed("WhisperKit is nil after loading")
            }
            return try await whisper.transcribe(
                audioArray: audioArray,
                decodeOptions: decodingOptions
            )
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
            return try await speaker.diarize(audioArray: audioArray)
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

        let rawResult = TranscriptResult(
            transcriptionMethodId: method.id,
            language: language,
            speakerCount: diarization.speakerCount,
            segments: segments,
            speakerEmbeddings: [:],
            processingDuration: elapsed
        )

        return TranscriptSanitizer.sanitize(rawResult, audioDuration: audioDuration)
    }
}

// MARK: - Model lifecycle helpers

private extension InProcessTranscriptionEngine {
    func loadAudioSamples(fromPath path: String) throws -> [Float] {
        guard FileManager.default.fileExists(atPath: path) else {
            throw TranscriptionError.invalidInput("Audio file does not exist: \(path)")
        }
        do {
            let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
            guard !samples.isEmpty else {
                throw TranscriptionError.invalidInput(
                    "Audio file produced zero samples: \(path)"
                )
            }
            return samples
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.invalidInput(
                "Failed to load audio from \(path): \(error.localizedDescription)"
            )
        }
    }

    func ensureWhisperKitLoaded() async throws {
        if whisperKit == nil {
            await statusMachine.transition(to: .loading)
            do {
                whisperKit = try await WhisperKit(
                    makeWhisperConfig(load: true, download: true)
                )
            } catch {
                let wrappedError = TranscriptionError.modelLoadFailed(
                    "WhisperKit init failed: \(error.localizedDescription)"
                )
                await statusMachine.transition(to: .error(wrappedError))
                throw wrappedError
            }
            await statusMachine.transition(to: .ready)
        } else {
            try await whisperKit?.loadModels()
        }
    }

    func ensureSpeakerKitLoaded() async throws {
        if speakerKit == nil {
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
        } else {
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
    func makeWhisperConfig(load: Bool, download: Bool) -> WhisperKitConfig {
        WhisperKitConfig(
            model: resolvedSettings.sttModel,
            downloadBase: ModelStorage.downloadBase,
            modelRepo: resolvedSettings.sttModelRepo,
            verbose: false,
            load: load,
            download: download
        )
    }

    /// Build a SpeakerKit (Pyannote) configuration anchored at the shared cache.
    func makeSpeakerConfig(download: Bool, load: Bool) -> PyannoteConfig {
        PyannoteConfig(
            downloadBase: ModelStorage.downloadBase.path,
            download: download,
            load: load,
            verbose: false
        )
    }
}
