import Foundation
import LlamaSwift

/// Builds a llama.cpp sampler chain from `GenerationOptions`.
///
/// Chain order (llama.cpp standard): penalties -> top_k -> top_p -> min_p -> temp -> dist.
/// When temperature == 0, uses a single greedy sampler instead.
enum SamplerBuilder {
    /// Build and return a sampler chain. Caller is responsible for freeing via
    /// `llama_sampler_free`.
    static func buildChain(
        options: GenerationOptions,
        engineSeed: UInt64
    ) -> UnsafeMutablePointer<llama_sampler> {
        let seed = options.seed ?? engineSeed

        if options.temperature == 0 {
            // Greedy decoding: just argmax
            var chainParams = llama_sampler_chain_default_params()
            chainParams.no_perf = true
            // swiftlint:disable:next force_unwrapping
            let chain = llama_sampler_chain_init(chainParams)!
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
            return chain
        }

        var chainParams = llama_sampler_chain_default_params()
        chainParams.no_perf = true
        // swiftlint:disable:next force_unwrapping
        let chain = llama_sampler_chain_init(chainParams)!

        // Repetition penalty
        if options.repeatPenalty != 1.0 {
            llama_sampler_chain_add(
                chain,
                llama_sampler_init_penalties(
                    Int32(options.repeatLastN),
                    options.repeatPenalty,
                    0.0, // frequency penalty (unused, Gemma default)
                    0.0 // presence penalty (unused, Gemma default)
                )
            )
        }

        llama_sampler_chain_add(chain, llama_sampler_init_top_k(Int32(options.topK)))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(options.topP, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_min_p(options.minP, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(options.temperature))
        // llama_sampler_init_dist takes UInt32; truncate the UInt64 seed to its
        // lower 32 bits. This is a limitation of the llama.cpp API.
        llama_sampler_chain_add(
            chain,
            llama_sampler_init_dist(UInt32(seed & 0xFFFF_FFFF))
        )

        return chain
    }
}
