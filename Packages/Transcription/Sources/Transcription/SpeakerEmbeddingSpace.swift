import ArgmaxCore
import SpeakerKit

/// Builds embedding space keys from SpeakerKit's model metadata.
///
/// A space key describes the models that produced a set of centroids. Voiceprints
/// from different spaces cannot be compared. The key changes automatically when
/// SpeakerKit selects different model variants (e.g. on a new OS version).
public enum SpeakerEmbeddingSpace {
    /// The embedding space key for the current SpeakerKit embedder model.
    ///
    /// Format: `"<embedder version>/<embedder variant>"`,
    /// e.g. `"pyannote-v3/W8A16"`.
    public static func current() -> String {
        let embedder = ModelInfo.embedder()
        return "\(embedder.version ?? "unknown")/\(embedder.variant ?? "unknown")"
    }
}
