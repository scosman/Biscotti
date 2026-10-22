import Testing
@testable import STTLabAnalysis

@Suite("WER")
struct WERTests {

    func makeTokens(_ words: [String]) -> [NormToken] {
        words.enumerated().map { NormToken(text: $0.element, sourceIndex: $0.offset) }
    }

    @Test("Identical sequences: zero WER")
    func identical() {
        let ref = makeTokens(["the", "cat", "sat"])
        let hyp = makeTokens(["the", "cat", "sat"])
        let result = WER.compute(ref: ref, hyp: hyp)
        #expect(result.wer == 0)
        #expect(result.substitutions == 0)
        #expect(result.deletions == 0)
        #expect(result.insertions == 0)
    }

    @Test("One substitution")
    func oneSubstitution() {
        let ref = makeTokens(["the", "cat", "sat"])
        let hyp = makeTokens(["the", "dog", "sat"])
        let result = WER.compute(ref: ref, hyp: hyp)
        #expect(result.substitutions == 1)
        #expect(result.deletions == 0)
        #expect(result.insertions == 0)
        #expect(result.refWords == 3)
        // WER = 1/3
        #expect(result.wer != nil)
        #expect(abs(result.wer! - 1.0 / 3.0) < 0.001)
    }

    @Test("Deletions")
    func deletions() {
        let ref = makeTokens(["the", "cat", "sat", "down"])
        let hyp = makeTokens(["the", "sat"])
        let result = WER.compute(ref: ref, hyp: hyp)
        #expect(result.deletions == 2)
        #expect(result.substitutions == 0)
        #expect(result.insertions == 0)
    }

    @Test("Insertions")
    func insertions() {
        let ref = makeTokens(["the", "cat"])
        let hyp = makeTokens(["the", "big", "fat", "cat"])
        let result = WER.compute(ref: ref, hyp: hyp)
        #expect(result.insertions == 2)
        #expect(result.deletions == 0)
        #expect(result.substitutions == 0)
    }

    @Test("Empty reference: nil WER")
    func emptyRef() {
        let ref: [NormToken] = []
        let hyp = makeTokens(["hello"])
        let result = WER.compute(ref: ref, hyp: hyp)
        #expect(result.wer == nil)
        #expect(result.refWords == 0)
    }

    @Test("Pool results")
    func pooling() {
        let r1 = WERResult(refWords: 100, substitutions: 5, deletions: 3, insertions: 2)
        let r2 = WERResult(refWords: 50, substitutions: 2, deletions: 1, insertions: 0)
        let pooled = WER.pool([r1, r2])
        #expect(pooled.refWords == 150)
        #expect(pooled.substitutions == 7)
        #expect(pooled.deletions == 4)
        #expect(pooled.insertions == 2)
        // WER = 13/150
        #expect(pooled.wer != nil)
        #expect(abs(pooled.wer! - 13.0 / 150.0) < 0.001)
    }
}
