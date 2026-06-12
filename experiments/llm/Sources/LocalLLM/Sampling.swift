import Foundation
import LlamaSwift

// MARK: - Built-in sampler chain (preferred)

/// Builds a llama.cpp sampler chain from `GenerationOptions`.
///
/// Chain order (llama.cpp standard): penalties -> top_k -> top_p -> min_p -> temp -> dist.
/// When temperature == 0, uses a single greedy sampler instead.
enum SamplerBuilder {
    /// Build and return a sampler chain. Caller is responsible for freeing via
    /// `llama_sampler_free`.
    static func buildChain(options: GenerationOptions, engineSeed: UInt64) -> UnsafeMutablePointer<llama_sampler> {
        let seed = options.seed ?? engineSeed

        if options.temperature == 0 {
            // Greedy decoding: just argmax
            var chainParams = llama_sampler_chain_default_params()
            chainParams.no_perf = true
            let chain = llama_sampler_chain_init(chainParams)!
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
            return chain
        }

        var chainParams = llama_sampler_chain_default_params()
        chainParams.no_perf = true
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
        // llama_sampler_init_dist takes UInt32; truncate the UInt64 seed to its lower 32 bits.
        // Two UInt64 seeds sharing the same low 32 bits will produce identical sampling output
        // on the built-in path. This is a limitation of the llama.cpp API.
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32(seed & 0xFFFF_FFFF)))

        return chain
    }
}

// MARK: - Hand-rolled fallback (pure, testable transforms)

/// Pure sampling transforms over logit arrays. Used as a fallback if the built-in sampler chain
/// has issues, and for unit testing the sampling math in isolation.
public enum SamplingFallback {
    /// Apply repetition penalty to logits for recently generated tokens.
    public static func applyRepeatPenalty(
        logits: inout [Float],
        recentTokens: [Int32],
        penalty: Float
    ) {
        guard penalty != 1.0 else { return }
        for tokenID in recentTokens {
            let idx = Int(tokenID)
            guard idx >= 0, idx < logits.count else { continue }
            // If logit > 0, divide by penalty; if <= 0, multiply by penalty
            if logits[idx] > 0 {
                logits[idx] /= penalty
            } else {
                logits[idx] *= penalty
            }
        }
    }

    /// Scale logits by temperature. Temperature of 0 is undefined here (use argmax instead).
    public static func applyTemperature(logits: inout [Float], temperature: Float) {
        guard temperature > 0, temperature != 1.0 else { return }
        for i in logits.indices {
            logits[i] /= temperature
        }
    }

    /// Top-K: keep only the K highest-probability tokens, zero out the rest.
    /// Returns sorted (index, logit) pairs of the top K candidates.
    public static func topK(_ logits: [Float], k: Int) -> [(index: Int, logit: Float)] {
        let indexed = logits.enumerated().map { (index: $0.offset, logit: $0.element) }
        let sorted = indexed.sorted { $0.logit > $1.logit }
        return Array(sorted.prefix(k))
    }

    /// Top-P (nucleus): from a sorted candidate list, keep candidates until cumulative
    /// probability exceeds p. Returns the filtered candidates.
    public static func topP(
        _ candidates: [(index: Int, logit: Float)],
        p: Float
    ) -> [(index: Int, logit: Float)] {
        guard p < 1.0 else { return candidates }
        let probs = softmax(candidates.map(\.logit))
        var cumulative: Float = 0
        var result: [(index: Int, logit: Float)] = []
        for (i, candidate) in candidates.enumerated() {
            cumulative += probs[i]
            result.append(candidate)
            if cumulative >= p { break }
        }
        return result
    }

    /// Min-P: remove candidates whose probability is less than minP * max_probability.
    public static func minP(
        _ candidates: [(index: Int, logit: Float)],
        p: Float
    ) -> [(index: Int, logit: Float)] {
        guard p > 0, !candidates.isEmpty else { return candidates }
        let probs = softmax(candidates.map(\.logit))
        guard let maxProb = probs.max(), maxProb > 0 else { return candidates }
        let threshold = p * maxProb
        return zip(candidates, probs).compactMap { candidate, prob in
            prob >= threshold ? candidate : nil
        }
    }

    /// Argmax over logits. Returns the index of the highest logit.
    public static func argmax(_ logits: [Float]) -> Int {
        guard !logits.isEmpty else { return 0 }
        var maxIdx = 0
        var maxVal = logits[0]
        for i in 1 ..< logits.count {
            if logits[i] > maxVal {
                maxVal = logits[i]
                maxIdx = i
            }
        }
        return maxIdx
    }

    /// Softmax over a logit array. Returns probabilities that sum to 1.
    public static func softmax(_ logits: [Float]) -> [Float] {
        guard !logits.isEmpty else { return [] }
        let maxLogit = logits.max()!
        let exps = logits.map { exp($0 - maxLogit) }
        let sum = exps.reduce(0, +)
        guard sum > 0 else { return logits.map { _ in 1.0 / Float(logits.count) } }
        return exps.map { $0 / sum }
    }

    /// Sample from a probability distribution using a seeded RNG.
    public static func sampleFromDistribution(
        _ candidates: [(index: Int, logit: Float)],
        seed: UInt64
    ) -> Int {
        guard !candidates.isEmpty else { return 0 }
        let probs = softmax(candidates.map(\.logit))
        // LCG (Knuth's constants) for reproducibility. Two warm-up steps advance the
        // state past the seed's low-entropy neighborhood before extracting a value.
        var rng = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let randomFloat = Float(rng >> 33) / Float(1 << 31)
        var cumulative: Float = 0
        for (i, prob) in probs.enumerated() {
            cumulative += prob
            if randomFloat < cumulative {
                return candidates[i].index
            }
        }
        return candidates.last!.index
    }
}
