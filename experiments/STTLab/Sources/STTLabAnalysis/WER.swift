/// Word Error Rate result with substitution, deletion, and insertion counts.
public struct WERResult: Codable, Sendable, Equatable {
    /// Number of reference words.
    public var refWords: Int
    /// Number of substitutions.
    public var substitutions: Int
    /// Number of deletions (ref word missing from hypothesis).
    public var deletions: Int
    /// Number of insertions (extra word in hypothesis).
    public var insertions: Int
    /// WER = (S+D+I) / refWords. Nil when refWords == 0.
    public var wer: Double?

    public init(refWords: Int, substitutions: Int, deletions: Int, insertions: Int) {
        self.refWords = refWords
        self.substitutions = substitutions
        self.deletions = deletions
        self.insertions = insertions
        self.wer = refWords > 0 ? Double(substitutions + deletions + insertions) / Double(refWords) : nil
    }
}

/// Computes WER between a reference and a hypothesis transcript.
public enum WER {

    /// Compute WER. `ref` tokens are the reference; `hyp` tokens are the hypothesis.
    /// Both should already be normalized.
    public static func compute(ref: [NormToken], hyp: [NormToken]) -> WERResult {
        let refStrings = ref.map(\.text)
        let hypStrings = hyp.map(\.text)
        let ops = Aligner.align(refStrings, hypStrings)
        let counts = Aligner.opCounts(ops)
        return WERResult(
            refWords: refStrings.count,
            substitutions: counts.subs,
            deletions: counts.dels,
            insertions: counts.ins
        )
    }

    /// Compute WER from raw engine words (normalizes internally).
    public static func compute(ref: [EngineWord], hyp: [EngineWord]) -> WERResult {
        compute(ref: Normalizer.tokens(for: ref), hyp: Normalizer.tokens(for: hyp))
    }

    /// Pool multiple WERResults by summing errors and reference words.
    public static func pool(_ results: [WERResult]) -> WERResult {
        let totalRef = results.reduce(0) { $0 + $1.refWords }
        let totalSub = results.reduce(0) { $0 + $1.substitutions }
        let totalDel = results.reduce(0) { $0 + $1.deletions }
        let totalIns = results.reduce(0) { $0 + $1.insertions }
        return WERResult(refWords: totalRef, substitutions: totalSub,
                         deletions: totalDel, insertions: totalIns)
    }
}
