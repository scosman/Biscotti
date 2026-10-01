import ArgmaxCore
import SpeakerKit

/// Builds embedding space keys from SpeakerKit's model metadata.
///
/// A space key describes the models that produced a set of centroids. Voiceprints
/// from different spaces cannot be compared. The key changes automatically when
/// SpeakerKit selects different model variants (e.g. on a new OS version).
public enum SpeakerEmbeddingSpace {
    /// The embedding space key for the current SpeakerKit models.
    ///
    /// - Raw: `"<embedder version>/<embedder variant>"`,
    ///   e.g. `"pyannote-v3/W8A16"`.
    /// - PLDA: raw key + `"+plda:<plda version>/<plda variant>"`,
    ///   e.g. `"pyannote-v3/W8A16+plda:pyannote-v4/W32A32"`.
    public static func current(_ kind: EmbeddingKind) -> String {
        let embedder = ModelInfo.embedder()
        let embedderKey = "\(embedder.version ?? "unknown")/\(embedder.variant ?? "unknown")"

        switch kind {
        case .raw:
            return embedderKey
        case .plda:
            let plda = ModelInfo.plda()
            let pldaKey = "\(plda.version ?? "unknown")/\(plda.variant ?? "unknown")"
            return "\(embedderKey)+plda:\(pldaKey)"
        }
    }
}
