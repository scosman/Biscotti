/// Public API for estimated transcription model download size.
///
/// Promotes the engine's private per-model-variant size table so the
/// app layer can compute click-time disk-space requirements without
/// hardcoding a fixed value or importing engine internals.
public enum TranscriptionDownloadSize {
    /// Estimated total download size in bytes for the STT + diarization
    /// models used by the given transcription method.
    ///
    /// The estimate is conservative (model on-disk size + headroom) and
    /// includes the SpeakerKit (~33 MB) component.
    public static func estimatedBytes(
        method: TranscriptionMethod = .current
    ) -> Int64 {
        let settings = MethodResolver.resolve(method)
        return estimatedBytes(sttModel: settings.sttModel)
    }

    /// Internal: size lookup keyed on the STT model name.
    static func estimatedBytes(sttModel: String) -> Int64 {
        if sttModel.contains("1307MB") {
            1_400_000_000
        } else if sttModel.contains("1049MB") {
            1_150_000_000
        } else if sttModel.contains("954MB") {
            1_050_000_000
        } else if sttModel.contains("626MB") {
            750_000_000
        } else {
            3_300_000_000
        }
    }
}
