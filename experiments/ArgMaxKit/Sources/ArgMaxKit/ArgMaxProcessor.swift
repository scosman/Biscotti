import Foundation
import WhisperKit
import SpeakerKit

/// The main entry point for ArgMaxKit speech processing.
///
/// Wraps WhisperKit (STT) and SpeakerKit (diarization) behind a single
/// `processAudio` call that returns a rich `TranscriptResult`. Models are
/// lazily loaded on first use and can be explicitly unloaded to free memory.
///
/// In the real Steak app this will run inside an XPC service for crash isolation.
/// The CLI harness exercises the same code path in-process.
public actor ArgMaxProcessor {

    private let config: ProcessorConfig
    private var whisperKit: WhisperKit?
    private var speakerKit: SpeakerKit?

    public init(config: ProcessorConfig = .default) {
        self.config = config
    }

    // MARK: - Public API

    /// Download models if not already cached. Call during onboarding or first launch
    /// to avoid a delay on the first `processAudio` call.
    public func ensureModelsDownloaded() async throws {
        // WhisperKit downloads models during init when download=true (default).
        // Creating an instance with load=false downloads without loading into memory.
        if whisperKit == nil {
            do {
                let whisperConfig = WhisperKitConfig(
                    model: config.sttModel,
                    modelRepo: config.sttModelRepo,
                    verbose: true,
                    load: false,
                    download: true
                )
                whisperKit = try await WhisperKit(whisperConfig)
            } catch {
                throw ArgMaxError.modelLoadFailed("WhisperKit download failed: \(error.localizedDescription)")
            }
        }

        // SpeakerKit downloads during init.
        if speakerKit == nil {
            do {
                speakerKit = try await SpeakerKit()
            } catch {
                throw ArgMaxError.modelLoadFailed("SpeakerKit download failed: \(error.localizedDescription)")
            }
        }
    }

    /// Process an audio file and return a rich diarized transcript.
    ///
    /// - Parameters:
    ///   - file: URL to an audio file (WAV, CAF, M4A, MP3, etc.)
    ///   - customVocabulary: Domain-specific terms to boost recognition of.
    ///     Formatted into a conditioning prompt for Whisper's decoder.
    /// - Returns: A `TranscriptResult` with segments, speaker IDs, and word timings.
    public func processAudio(
        _ file: URL,
        customVocabulary: [String] = []
    ) async throws -> TranscriptResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Validate the file exists
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw ArgMaxError.invalidAudioFile(file, underlying: "File does not exist")
        }

        // 1. Load audio as float array (16 kHz mono PCM)
        let audioArray: [Float]
        do {
            audioArray = try AudioProcessor.loadAudioAsFloatArray(fromPath: file.path)
        } catch {
            throw ArgMaxError.audioLoadFailed(file, underlying: error.localizedDescription)
        }

        guard !audioArray.isEmpty else {
            throw ArgMaxError.audioLoadFailed(file, underlying: "Audio file produced zero samples")
        }

        // 2. Run STT (WhisperKit)
        let transcriptionResults: [TranscriptionResult]
        do {
            try await ensureWhisperKitLoaded()

            var decodingOptions = DecodingOptions(
                wordTimestamps: config.enableWordTimestamps
            )

            // Apply custom vocabulary as prompt conditioning
            if let promptText = VocabularyFormatter.formatPrompt(from: customVocabulary) {
                if let tokenizer = whisperKit?.tokenizer {
                    decodingOptions.promptTokens = tokenizer.encode(text: promptText)
                }
            }

            guard let wk = whisperKit else {
                throw ArgMaxError.modelLoadFailed("WhisperKit is nil after loading")
            }
            transcriptionResults = try await wk.transcribe(
                audioArray: audioArray,
                decodeOptions: decodingOptions
            )
        } catch let error as ArgMaxError {
            throw error
        } catch {
            throw ArgMaxError.transcriptionFailed(error.localizedDescription)
        }

        // Optionally unload WhisperKit before loading SpeakerKit (saves ~2 GB on 8 GB Macs)
        if config.sequentialLoading {
            await unloadWhisperKit()
        }

        // 3. Run diarization (SpeakerKit)
        let diarizationResult: DiarizationResult
        do {
            try await ensureSpeakerKitLoaded()

            guard let sk = speakerKit else {
                throw ArgMaxError.modelLoadFailed("SpeakerKit is nil after loading")
            }
            diarizationResult = try await sk.diarize(audioArray: audioArray)
        } catch let error as ArgMaxError {
            throw error
        } catch {
            throw ArgMaxError.diarizationFailed(error.localizedDescription)
        }

        // Optionally unload SpeakerKit after diarization
        if config.sequentialLoading {
            await unloadSpeakerKit()
        }

        // 4. Merge transcription + diarization
        let diarizationStrategy: SpeakerInfoStrategy = switch config.diarizationStrategy {
        case .subsegment: .subsegment
        case .segment: .segment
        }

        let speakerSegmentGroups = diarizationResult.addSpeakerInfo(
            to: transcriptionResults,
            strategy: diarizationStrategy
        )

        // 5. Build our clean TranscriptResult
        let language = transcriptionResults.first?.language ?? "unknown"
        let segments = buildSegments(from: speakerSegmentGroups)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        // NOTE: Speaker centroid embeddings are not exposed by the free SpeakerKit v1.0.0 API.
        // The clustering happens internally in Pyannote but the embeddings are not surfaced.
        // Cross-file speaker matching will need a future SDK update or custom extraction.
        // We keep the field in TranscriptResult (empty dict) so the data model is ready.
        let speakerEmbeddings: [Int: [Float]] = [:]

        return TranscriptResult(
            modelVersion: config.sttModel,
            language: language,
            speakerCount: diarizationResult.speakerCount,
            segments: segments,
            speakerEmbeddings: speakerEmbeddings,
            processingDuration: elapsed
        )
    }

    /// Explicitly unload all models from memory.
    /// The processor remains usable; models will be re-loaded on the next call.
    public func unloadModels() async {
        await unloadWhisperKit()
        await unloadSpeakerKit()
    }

    /// Check if the processor can initialize (basic health check).
    public func isAvailable() async -> Bool {
        // For the CLI/in-process case this is always true.
        // In an XPC scenario this would check the connection.
        return true
    }

    // MARK: - Private Helpers

    private func ensureWhisperKitLoaded() async throws {
        if whisperKit == nil {
            do {
                let whisperConfig = WhisperKitConfig(
                    model: config.sttModel,
                    modelRepo: config.sttModelRepo,
                    verbose: true,
                    load: true,
                    download: true
                )
                whisperKit = try await WhisperKit(whisperConfig)
            } catch {
                throw ArgMaxError.modelLoadFailed("WhisperKit init failed: \(error.localizedDescription)")
            }
        } else {
            // Models may have been downloaded but not loaded (ensureModelsDownloaded with load=false)
            try await whisperKit?.loadModels()
        }
    }

    private func ensureSpeakerKitLoaded() async throws {
        if speakerKit == nil {
            do {
                speakerKit = try await SpeakerKit()
            } catch {
                throw ArgMaxError.modelLoadFailed("SpeakerKit init failed: \(error.localizedDescription)")
            }
        } else {
            try await speakerKit?.ensureModelsLoaded()
        }
    }

    private func unloadWhisperKit() async {
        // nil-ing the instance releases all model memory; unloadModels() is
        // called first for a clean teardown in case the SDK does async cleanup.
        await whisperKit?.unloadModels()
        whisperKit = nil
    }

    private func unloadSpeakerKit() async {
        await speakerKit?.unloadModels()
        speakerKit = nil
    }

    private func buildSegments(from groups: [[SpeakerSegment]]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []

        for group in groups {
            for speakerSegment in group {
                let speakerID = speakerSegment.speaker.speakerId
                let speakerLabel = speakerSegment.speaker.description

                let words: [TranscriptWord]? = speakerSegment.speakerWords.isEmpty ? nil :
                    speakerSegment.speakerWords.map { swt in
                        TranscriptWord(
                            word: swt.wordTiming.word,
                            startTime: TimeInterval(swt.wordTiming.start),
                            endTime: TimeInterval(swt.wordTiming.end),
                            probability: swt.wordTiming.probability,
                            speakerID: swt.speaker.speakerId
                        )
                    }

                let confidence: Float
                let noSpeechProb: Float
                if let transcription = speakerSegment.transcription {
                    confidence = transcription.avgLogprob
                    noSpeechProb = transcription.noSpeechProb
                } else {
                    confidence = 0
                    noSpeechProb = 0
                }

                result.append(TranscriptSegment(
                    speakerID: speakerID,
                    speakerLabel: speakerLabel,
                    startTime: TimeInterval(speakerSegment.startTime),
                    endTime: TimeInterval(speakerSegment.endTime),
                    text: speakerSegment.text,
                    confidence: confidence,
                    noSpeechProbability: noSpeechProb,
                    words: words
                ))
            }
        }

        return result
    }
}
