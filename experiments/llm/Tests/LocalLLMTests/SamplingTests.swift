import Testing

@testable import LocalLLM

@Suite("SamplingFallback")
struct SamplingTests {
    @Test("Argmax returns index of highest logit")
    func argmaxBasic() {
        let logits: [Float] = [1.0, 3.0, 2.0, 0.5]
        #expect(SamplingFallback.argmax(logits) == 1)
    }

    @Test("Argmax with all equal returns 0")
    func argmaxAllEqual() {
        let logits: [Float] = [1.0, 1.0, 1.0]
        #expect(SamplingFallback.argmax(logits) == 0)
    }

    @Test("Argmax with negative logits")
    func argmaxNegative() {
        let logits: [Float] = [-3.0, -1.0, -2.0]
        #expect(SamplingFallback.argmax(logits) == 1)
    }

    @Test("Argmax empty returns 0")
    func argmaxEmpty() {
        #expect(SamplingFallback.argmax([]) == 0)
    }

    @Test("Top-K returns K highest elements sorted descending")
    func topKBasic() {
        let logits: [Float] = [1.0, 5.0, 3.0, 2.0, 4.0]
        let result = SamplingFallback.topK(logits, k: 3)
        #expect(result.count == 3)
        #expect(result[0].index == 1) // 5.0
        #expect(result[1].index == 4) // 4.0
        #expect(result[2].index == 2) // 3.0
    }

    @Test("Top-K with K larger than vocab returns all")
    func topKLargeK() {
        let logits: [Float] = [1.0, 2.0]
        let result = SamplingFallback.topK(logits, k: 10)
        #expect(result.count == 2)
    }

    @Test("Top-P keeps candidates until cumulative >= p")
    func topPBasic() {
        // After softmax of [10, 5, 1], the first element dominates
        let candidates: [(index: Int, logit: Float)] = [
            (index: 0, logit: 10.0),
            (index: 1, logit: 5.0),
            (index: 2, logit: 1.0),
        ]
        let result = SamplingFallback.topP(candidates, p: 0.95)
        // The top candidate's probability (softmax of 10 vs 5,1) is ~0.993, so just 1 element
        #expect(result.count >= 1)
        #expect(result[0].index == 0)
    }

    @Test("Top-P with p=1.0 returns all candidates")
    func topPFull() {
        let candidates: [(index: Int, logit: Float)] = [
            (index: 0, logit: 1.0),
            (index: 1, logit: 1.0),
        ]
        let result = SamplingFallback.topP(candidates, p: 1.0)
        #expect(result.count == 2)
    }

    @Test("Min-P filters low-probability candidates")
    func minPBasic() {
        // After softmax: [10, 1, 0] -> first dominates heavily
        let candidates: [(index: Int, logit: Float)] = [
            (index: 0, logit: 10.0),
            (index: 1, logit: 1.0),
            (index: 2, logit: 0.0),
        ]
        let result = SamplingFallback.minP(candidates, p: 0.1)
        // Token at index 0 has probability ~0.9998, tokens at 1,2 are far below 0.1 * max
        #expect(result.count >= 1)
        #expect(result[0].index == 0)
    }

    @Test("Min-P with p=0 returns all candidates")
    func minPZero() {
        let candidates: [(index: Int, logit: Float)] = [
            (index: 0, logit: 5.0),
            (index: 1, logit: 1.0),
        ]
        let result = SamplingFallback.minP(candidates, p: 0.0)
        #expect(result.count == 2)
    }

    @Test("Temperature scaling divides logits")
    func temperatureScaling() {
        var logits: [Float] = [2.0, 4.0, 6.0]
        SamplingFallback.applyTemperature(logits: &logits, temperature: 2.0)
        #expect(logits[0] == 1.0)
        #expect(logits[1] == 2.0)
        #expect(logits[2] == 3.0)
    }

    @Test("Temperature 1.0 is a no-op")
    func temperatureOne() {
        var logits: [Float] = [2.0, 4.0]
        SamplingFallback.applyTemperature(logits: &logits, temperature: 1.0)
        #expect(logits[0] == 2.0)
        #expect(logits[1] == 4.0)
    }

    @Test("Repeat penalty reduces positive logits and boosts negative")
    func repeatPenalty() {
        var logits: [Float] = [2.0, -1.0, 3.0, 0.5]
        SamplingFallback.applyRepeatPenalty(logits: &logits, recentTokens: [0, 1], penalty: 2.0)
        #expect(logits[0] == 1.0) // 2.0 / 2.0 (positive, divided)
        #expect(logits[1] == -2.0) // -1.0 * 2.0 (negative, multiplied)
        #expect(logits[2] == 3.0) // unchanged
        #expect(logits[3] == 0.5) // unchanged
    }

    @Test("Repeat penalty 1.0 is a no-op")
    func repeatPenaltyOne() {
        var logits: [Float] = [2.0, -1.0]
        SamplingFallback.applyRepeatPenalty(logits: &logits, recentTokens: [0, 1], penalty: 1.0)
        #expect(logits[0] == 2.0)
        #expect(logits[1] == -1.0)
    }

    @Test("Softmax produces valid probability distribution")
    func softmaxDistribution() {
        let logits: [Float] = [1.0, 2.0, 3.0]
        let probs = SamplingFallback.softmax(logits)
        #expect(probs.count == 3)
        let sum = probs.reduce(0, +)
        #expect(abs(sum - 1.0) < 0.001)
        // Probabilities should be monotonically increasing
        #expect(probs[0] < probs[1])
        #expect(probs[1] < probs[2])
    }

    @Test("Softmax of equal logits produces uniform distribution")
    func softmaxUniform() {
        let logits: [Float] = [1.0, 1.0, 1.0]
        let probs = SamplingFallback.softmax(logits)
        for p in probs {
            #expect(abs(p - 1.0 / 3.0) < 0.001)
        }
    }

    @Test("Softmax empty returns empty")
    func softmaxEmpty() {
        #expect(SamplingFallback.softmax([]).isEmpty)
    }

    @Test("Seeded sampling is deterministic")
    func seededDeterminism() {
        let candidates: [(index: Int, logit: Float)] = [
            (index: 0, logit: 1.0),
            (index: 1, logit: 1.0),
            (index: 2, logit: 1.0),
        ]
        let result1 = SamplingFallback.sampleFromDistribution(candidates, seed: 42)
        let result2 = SamplingFallback.sampleFromDistribution(candidates, seed: 42)
        #expect(result1 == result2)
    }
}
