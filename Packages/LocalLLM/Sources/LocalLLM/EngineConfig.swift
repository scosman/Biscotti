/// Load-time configuration for the LLM engine.
///
/// Controls model loading parameters and context allocation. Immutable after creation.
public struct EngineConfig: Sendable, Codable, Equatable {
    /// Context window size in tokens. Gemma 4 12B supports up to 128k but 32k is practical
    /// for meeting transcript workloads and keeps memory manageable.
    public var contextSize: Int

    /// Number of model layers to offload to GPU. 99 means "all" on Apple Silicon.
    public var nGpuLayers: Int

    /// Thread count for CPU compute. nil uses the llama.cpp default (hardware threads).
    public var threadCount: Int?

    /// RNG seed for reproducibility. Used as the default when GenerationOptions.seed is nil.
    /// Note: the built-in sampler path (llama.cpp) only uses the lower 32 bits.
    public var seed: UInt64

    public init(
        contextSize: Int = 32768,
        nGpuLayers: Int = 99,
        threadCount: Int? = nil,
        seed: UInt64 = 42
    ) {
        self.contextSize = contextSize
        self.nGpuLayers = nGpuLayers
        self.threadCount = threadCount
        self.seed = seed
    }

    /// Sensible defaults for Gemma 4 12B on Apple Silicon.
    public static let `default` = EngineConfig()
}
