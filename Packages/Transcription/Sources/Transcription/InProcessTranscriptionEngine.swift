import Foundation
import SpeakerKit
import WhisperKit

/// In-process implementation of `TranscriptionEngine`.
///
/// Refactored from `ArgMaxProcessor` in the experiment. Runs WhisperKit (STT)
/// and SpeakerKit (diarization) in the calling process. Used by the CLI harness
/// and as the fallback when no XPC host is present.
public actor InProcessTranscriptionEngine: TranscriptionEngine {
    private let config: ProcessorConfig
    private let statusMachine: ModelStatusMachine
    private let diskSpaceChecker: DiskSpaceChecking
    private var whisperKit: WhisperKit?
    private var speakerKit: SpeakerKit?

    /// Estimated bytes required for model download (STT + diarization).
    /// Full-precision turbo ~3.1 GB + SpeakerKit ~33 MB; quantized ~1.3 GB + 33 MB.
    /// We use a conservative estimate based on the model name.
    private var estimatedDownloadBytes: Int64 {
        if config.sttModel.contains("1307MB") {
            1_400_000_000 // ~1.3 GB + headroom
        } else if config.sttModel.contains("954MB") {
            1_050_000_000
        } else if config.sttModel.contains("1049MB") {
            1_150_000_000
        } else {
            3_300_000_000 // full-precision ~3.1 GB + headroom
        }
    }

    public init(
        config: ProcessorConfig = .ramAware()
    ) {
        self.config = config
        statusMachine = ModelStatusMachine(initial: .needsDownload)
        diskSpaceChecker = SystemDiskSpaceChecker()
    }

    /// Internal init for testing with an injected disk-space checker.
    init(
        config: ProcessorConfig = .ramAware(),
        diskSpaceChecker: DiskSpaceChecking
    ) {
        self.config = config
        statusMachine = ModelStatusMachine(initial: .needsDownload)
        self.diskSpaceChecker = diskSpaceChecker
    }

    // MARK: - TranscriptionEngine

    public func ensureModelsDownloaded(
        progress: @Sendable (Double) -> Void
    ) async throws {
        try await checkDiskSpace()

        await statusMachine.transition(to: .downloading(progress: 0.0))
        progress(0.0)

        try await downloadWhisperKitIfNeeded(progress: progress)
        try await downloadSpeakerKitIfNeeded(progress: progress)

        progress(1.0)
    }

    /// Process audio using the passed-in `config` for all behavior in this call,
    /// including model loading/downloading, decoding options, and diarization strategy.
    public func processAudio(
        micPath: String?,
        systemPath: String?,
        mergedPath: String?,
        config: ProcessorConfig,
        customVocabulary: [String]
    ) async throws -> TranscriptResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        let mergeResult = try loadAndMergeAudio(
            micPath: micPath, systemPath: systemPath, mergedPath: mergedPath
        )

        await statusMachine.transition(to: .running)

        let sttResults = try await runSTT(
            audioArray: mergeResult.samples, config: config, customVocabulary: customVocabulary
        )

        if config.sequentialLoading { await unloadWhisperKit() }

        let diarization = try await runDiarization(audioArray: mergeResult.samples)

        if config.sequentialLoading { await unloadSpeakerKit() }

        let result = assembleResult(
            sttResults: sttResults, diarization: diarization,
            config: config, audioDuration: mergeResult.duration, startTime: startTime
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

// MARK: - Download helpers

private extension InProcessTranscriptionEngine {
    func checkDiskSpace() async throws {
        do {
            try diskSpaceChecker.checkAvailableSpace(requiredBytes: estimatedDownloadBytes)
        } catch let error as TranscriptionError {
            await statusMachine.transition(to: .error(error))
            throw error
        } catch {
            // Unexpected error type from the checker; wrap it
            let wrappedError = TranscriptionError.insufficientDisk(
                requiredBytes: estimatedDownloadBytes,
                availableBytes: 0
            )
            await statusMachine.transition(to: .error(wrappedError))
            throw wrappedError
        }
    }

    func downloadWhisperKitIfNeeded(
        progress: @Sendable (Double) -> Void
    ) async throws {
        guard whisperKit == nil else { return }
        do {
            let whisperConfig = WhisperKitConfig(
                model: config.sttModel,
                modelRepo: config.sttModelRepo,
                verbose: false,
                load: false,
                download: true
            )
            whisperKit = try await WhisperKit(whisperConfig)
            await statusMachine.transition(to: .downloading(progress: 0.8))
            progress(0.8)
        } catch {
            let wrappedError = TranscriptionError.downloadFailed(
                "WhisperKit download failed: \(error.localizedDescription)"
            )
            await statusMachine.transition(to: .error(wrappedError))
            throw wrappedError
        }
    }

    func downloadSpeakerKitIfNeeded(
        progress: @Sendable (Double) -> Void
    ) async throws {
        guard speakerKit == nil else { return }
        do {
            speakerKit = try await SpeakerKit()
            await statusMachine.transition(to: .downloading(progress: 1.0))
            progress(1.0)
        } catch {
            let wrappedError = TranscriptionError.downloadFailed(
                "SpeakerKit download failed: \(error.localizedDescription)"
            )
            await statusMachine.transition(to: .error(wrappedError))
            throw wrappedError
        }
    }
}

// MARK: - Processing helpers

private extension InProcessTranscriptionEngine {
    func loadAndMergeAudio(
        micPath: String?, systemPath: String?, mergedPath: String?
    ) throws -> MergeResult {
        guard micPath != nil || systemPath != nil || mergedPath != nil else {
            throw TranscriptionError.invalidInput(
                "At least one audio path (mic, system, or merged) must be provided"
            )
        }

        if let mergedPath {
            let samples = try loadAudioSamples(fromPath: mergedPath)
            return try AudioMerger.wrapMerged(samples)
        }

        let micSamples = try micPath.map { try loadAudioSamples(fromPath: $0) }
        let systemSamples = try systemPath.map { try loadAudioSamples(fromPath: $0) }
        return try AudioMerger.merge(mic: micSamples, system: systemSamples)
    }

    func runSTT(
        audioArray: [Float], config: ProcessorConfig, customVocabulary: [String]
    ) async throws -> [TranscriptionResult] {
        do {
            try await ensureWhisperKitLoaded(config: config)

            var decodingOptions = DecodingOptions(
                wordTimestamps: config.enableWordTimestamps
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
        config: ProcessorConfig,
        audioDuration: TimeInterval,
        startTime: CFAbsoluteTime
    ) -> TranscriptResult {
        let strategy: SpeakerInfoStrategy = switch config.diarizationStrategy {
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
            modelVersion: config.sttModel,
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

    func ensureWhisperKitLoaded(config: ProcessorConfig) async throws {
        if whisperKit == nil {
            await statusMachine.transition(to: .loading)
            do {
                let whisperConfig = WhisperKitConfig(
                    model: config.sttModel,
                    modelRepo: config.sttModelRepo,
                    verbose: false,
                    load: true,
                    download: true
                )
                whisperKit = try await WhisperKit(whisperConfig)
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
                speakerKit = try await SpeakerKit()
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
