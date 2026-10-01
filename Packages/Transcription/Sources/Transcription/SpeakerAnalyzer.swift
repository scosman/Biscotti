import Foundation
import os.log
import SpeakerKit

/// Runs speaker diarization without speech-to-text, for voiceprint backfill.
///
/// Used only by `voiceprint-cli backfill`. The app's transcription path goes
/// through ``InProcessTranscriptionEngine`` (which runs STT + diarization)
/// or ``XPCEngineAdapter``, so this actor is not wired into the XPC protocol.
public actor SpeakerAnalyzer {
    private static let log = Logger(
        subsystem: "net.scosman.biscotti",
        category: "SpeakerAnalyzer"
    )

    private var speakerKit: SpeakerKit?

    public init() {}

    /// Downloads SpeakerKit models into ``ModelStorage`` if missing.
    public func ensureModelsDownloaded() async throws {
        if speakerKit == nil {
            Self.log.info("SpeakerAnalyzer: downloading SpeakerKit models")
            do {
                speakerKit = try await SpeakerKit(
                    SpeakerKitConfigFactory.make(download: true, load: false)
                )
            } catch {
                throw TranscriptionError.downloadFailed(
                    "SpeakerKit download failed: \(error.localizedDescription)"
                )
            }
            Self.log.info("SpeakerAnalyzer: models ready")
        }
    }

    /// Run diarization on mic + system audio and return embedding sets and
    /// speech durations without running STT.
    public func analyze(micPath: String, systemPath: String) async throws -> SpeakerAnalysis {
        let mergeResult = try AudioLoading.loadAndMerge(
            micPath: micPath, systemPath: systemPath
        )

        if speakerKit == nil {
            speakerKit = try await SpeakerKit(
                SpeakerKitConfigFactory.make(download: true, load: false)
            )
        } else {
            try await speakerKit?.ensureModelsLoaded()
        }

        guard let speaker = speakerKit else {
            throw TranscriptionError.modelLoadFailed("SpeakerKit is nil after loading")
        }

        let diarization = try await speaker.diarize(
            audioArray: mergeResult.samples,
            options: DiarizationSettings.options
        )

        let spans = SpeakerDurations.spans(from: diarization)

        return SpeakerAnalysis(
            embeddingSets: EmbeddingSetBuilder.build(from: diarization),
            speakerSpeechDurations: SpeakerDurations.compute(spans),
            spans: spans
        )
    }

    /// Unload SpeakerKit models to free memory.
    public func unload() async {
        await speakerKit?.unloadModels()
        speakerKit = nil
    }
}

/// The result of a diarization-only analysis.
public struct SpeakerAnalysis: Sendable, Equatable {
    /// Per-kind centroid embedding sets.
    public let embeddingSets: [SpeakerEmbeddingSet]

    /// Total speaking time per diarization speaker.
    public let speakerSpeechDurations: [Int: TimeInterval]

    /// Individual diarized time spans, for speaker-mapping in backfill.
    public let spans: [DiarizedSpan]

    public init(
        embeddingSets: [SpeakerEmbeddingSet],
        speakerSpeechDurations: [Int: TimeInterval],
        spans: [DiarizedSpan]
    ) {
        self.embeddingSets = embeddingSets
        self.speakerSpeechDurations = speakerSpeechDurations
        self.spans = spans
    }
}
