import Foundation

/// A model descriptor from the curated catalog.
///
/// Each entry identifies a downloadable GGUF model with everything needed to
/// locate, download, and display it. The catalog is the single source of truth
/// for model identity and download coordinates; product policy (RAM gates,
/// recommendation, UI copy) lives in the app layer, not here.
public struct LLMModel: Sendable, Equatable, Identifiable {
    /// Stable identifier persisted as the user's selection (e.g. `"gemma-4-12b"`).
    public let id: String

    /// Human-readable name shown in the UI (e.g. `"Gemma 4 12B"`).
    public let displayName: String

    /// Remote URL from which the GGUF file is downloaded.
    public let downloadURL: URL

    /// The on-disk filename (== `downloadURL.lastPathComponent`). Models coexist
    /// in the shared cache directory distinguished by filename.
    public let fileName: String

    /// Approximate download size in bytes, used for the disk-space gate and
    /// delete-confirmation copy. Uses 1 GB = 1_000_000_000 (SI).
    public let approxDownloadBytes: Int64

    /// Whether this model's chat format ends a thinking-off generation prompt with an
    /// empty thought block (`<|channel>thought\n<channel|>`).
    ///
    /// Google's Gemma 4 template does this for the larger variants (12B and up), but
    /// **not** for E2B/E4B, whose thinking-off prompt ends at `<|turn>model\n`. The
    /// small models were never trained on the empty-thought prefill: given one, they
    /// write their reasoning into the answer and close it with a bare `<channel|>`.
    public let prefillsEmptyThoughtWhenThinkingOff: Bool

    public init(
        id: String,
        displayName: String,
        downloadURL: URL,
        fileName: String,
        approxDownloadBytes: Int64,
        prefillsEmptyThoughtWhenThinkingOff: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.downloadURL = downloadURL
        self.fileName = fileName
        self.approxDownloadBytes = approxDownloadBytes
        self.prefillsEmptyThoughtWhenThinkingOff = prefillsEmptyThoughtWhenThinkingOff
    }
}

/// The curated catalog of available LLM models.
///
/// Adding a new model = adding one entry to ``all``. No UI or logic rewrites
/// needed -- the rest of the system iterates over the catalog.
public enum LLMModelCatalog {
    // MARK: - Constants (SI: 1 GB = 1_000_000_000)

    private static let oneGB: Int64 = 1_000_000_000

    // MARK: - Catalog entries

    /// All available models in display order, largest first (12B, E4B, E2B).
    /// Display order is also used for fallback selection tie-breaks.
    public static let all: [LLMModel] = [
        LLMModel(
            id: "gemma-4-12b",
            displayName: "Gemma 4 12B",
            downloadURL: URL(
                string: "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/gemma-4-12b-it-UD-Q4_K_XL.gguf"
            )!,
            fileName: "gemma-4-12b-it-UD-Q4_K_XL.gguf",
            approxDownloadBytes: 7 * oneGB,
            prefillsEmptyThoughtWhenThinkingOff: true
        ),
        LLMModel(
            id: "gemma-4-e4b",
            displayName: "Gemma 4 E4B",
            downloadURL: URL(
                string: "https://huggingface.co/unsloth/gemma-4-E4B-it-qat-GGUF/resolve/main/gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf"
            )!,
            fileName: "gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf",
            approxDownloadBytes: 5 * oneGB,
            prefillsEmptyThoughtWhenThinkingOff: false
        ),
        LLMModel(
            id: "gemma-4-e2b",
            displayName: "Gemma 4 E2B",
            downloadURL: URL(
                string: "https://huggingface.co/unsloth/gemma-4-E2B-it-qat-GGUF/resolve/main/gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf"
            )!,
            fileName: "gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf",
            approxDownloadBytes: 3 * oneGB,
            prefillsEmptyThoughtWhenThinkingOff: false
        )
    ]

    /// Look up a catalog model by its stable identifier.
    ///
    /// Returns `nil` for unknown IDs (e.g. a stale persisted selection after a
    /// model is removed from the catalog in a future version).
    public static func model(id: String) -> LLMModel? {
        all.first { $0.id == id }
    }

    /// Look up the catalog model stored at `fileURL`, matched by file name.
    ///
    /// The file name is a catalog model's on-disk identity (see ``LLMModel/fileName``),
    /// and it is the only identity that reaches the engine, including across the XPC
    /// boundary. Returns `nil` for a file that is not a catalog model.
    public static func model(forFileAt fileURL: URL) -> LLMModel? {
        let fileName = fileURL.lastPathComponent
        return all.first { $0.fileName == fileName }
    }
}
