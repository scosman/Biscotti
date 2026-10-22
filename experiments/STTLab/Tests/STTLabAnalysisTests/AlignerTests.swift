import Testing
@testable import STTLabAnalysis

@Suite("Aligner")
struct AlignerTests {

    @Test("Empty sequences")
    func emptySequences() {
        let ops = Aligner.align([], [])
        #expect(ops.isEmpty)
    }

    @Test("Identical sequences")
    func identical() {
        let a = ["hello", "world"]
        let ops = Aligner.align(a, a)
        #expect(Aligner.cost(ops) == 0)
        let counts = Aligner.opCounts(ops)
        #expect(counts.matches == 2)
    }

    @Test("All deletions")
    func allDeletions() {
        let ops = Aligner.align(["a", "b", "c"], [])
        #expect(Aligner.cost(ops) == 3)
        let counts = Aligner.opCounts(ops)
        #expect(counts.dels == 3)
    }

    @Test("All insertions")
    func allInsertions() {
        let ops = Aligner.align([], ["a", "b"])
        #expect(Aligner.cost(ops) == 2)
        let counts = Aligner.opCounts(ops)
        #expect(counts.ins == 2)
    }

    @Test("Single substitution")
    func singleSub() {
        let ops = Aligner.align(["hello"], ["world"])
        #expect(Aligner.cost(ops) == 1)
        let counts = Aligner.opCounts(ops)
        #expect(counts.subs == 1)
    }

    @Test("Replay edit script: ops transform a into b")
    func replayEditScript() {
        let a = ["the", "cat", "sat", "on", "a", "mat"]
        let b = ["the", "dog", "sat", "on", "the", "mat"]
        let ops = Aligner.align(a, b)

        // Replay: apply ops to reconstruct b from a.
        var result: [String] = []
        for op in ops {
            switch op {
            case .match(let ai, _): result.append(a[ai])
            case .sub(_, let bi): result.append(b[bi])
            case .del: break
            case .ins(let bi): result.append(b[bi])
            }
        }
        #expect(result == b)
    }

    @Test("Hirschberg equals naive on 200 random pairs",
          .timeLimit(.minutes(2)))
    func hirschbergEqualsNaive() {
        var rng = SplitMix64(seed: 12345)
        let vocab = ["the", "cat", "sat", "on", "a", "mat"]

        for _ in 0..<200 {
            let aLen = Int(rng.next() % 61) // 0-60
            let bLen = Int(rng.next() % 61)
            let a = (0..<aLen).map { _ in vocab[Int(rng.next() % UInt64(vocab.count))] }
            let b = (0..<bLen).map { _ in vocab[Int(rng.next() % UInt64(vocab.count))] }

            let hirschOps = Aligner.align(a, b)
            let naiveOps = Aligner.alignNaive(a, b)

            let hCost = Aligner.cost(hirschOps)
            let nCost = Aligner.cost(naiveOps)
            #expect(hCost == nCost,
                    "Cost mismatch: hirsch=\(hCost), naive=\(nCost) for a=\(a), b=\(b)")

            let hCounts = Aligner.opCounts(hirschOps)
            let nCounts = Aligner.opCounts(naiveOps)
            #expect(hCounts.matches == nCounts.matches)
            #expect(hCounts.subs == nCounts.subs)
            #expect(hCounts.dels == nCounts.dels)
            #expect(hCounts.ins == nCounts.ins)

            // Verify the edit script replays a into b.
            var result: [String] = []
            for op in hirschOps {
                switch op {
                case .match(let ai, _): result.append(a[ai])
                case .sub(_, let bi): result.append(b[bi])
                case .del: break
                case .ins(let bi): result.append(b[bi])
                }
            }
            #expect(result == b, "Replay failed for a=\(a), b=\(b)")
        }
    }

    // MARK: - Hirschberg recursive-split coverage

    /// Helper: replay an edit script to reconstruct b from a.
    private func replay(_ ops: [EditOp], a: [String], b: [String]) -> [String] {
        var result: [String] = []
        for op in ops {
            switch op {
            case .match(let ai, _): result.append(a[ai])
            case .sub(_, let bi): result.append(b[bi])
            case .del: break
            case .ins(let bi): result.append(b[bi])
            }
        }
        return result
    }

    @Test("Hirschberg recursive path: threshold=0 forces every split",
          .timeLimit(.minutes(2)))
    func hirschbergDeepRecursion() {
        // With naiveThreshold=0 the base case never fires on m*n alone — only m<=1
        // or n==0 stops recursion. This exercises every level of the divide-and-conquer.
        var rng = SplitMix64(seed: 99999)
        let vocab = ["the", "cat", "sat", "on", "a", "mat", "big", "red"]

        for _ in 0..<200 {
            let aLen = Int(rng.next() % 31) + 2 // 2-32 (both > 1 so m<=1 doesn't short-circuit early)
            let bLen = Int(rng.next() % 31) + 2
            let a = (0..<aLen).map { _ in vocab[Int(rng.next() % UInt64(vocab.count))] }
            let b = (0..<bLen).map { _ in vocab[Int(rng.next() % UInt64(vocab.count))] }

            let hirschOps = Aligner.align(a, b, naiveThreshold: 0)
            let naiveOps = Aligner.alignNaive(a, b)

            let hCost = Aligner.cost(hirschOps)
            let nCost = Aligner.cost(naiveOps)
            #expect(hCost == nCost,
                    "Cost mismatch: hirsch=\(hCost) naive=\(nCost) a.count=\(a.count) b.count=\(b.count)")

            // S+D+I must equal cost.
            let hCounts = Aligner.opCounts(hirschOps)
            #expect(hCounts.subs + hCounts.dels + hCounts.ins == hCost,
                    "S+D+I != cost for hirschberg ops")

            // Edit script must replay a into b.
            #expect(replay(hirschOps, a: a, b: b) == b,
                    "Replay failed for a=\(a), b=\(b)")
        }
    }

    @Test("Hirschberg above default threshold: large input produces valid alignment")
    func hirschbergLargeInput() {
        // 100 x 100 = 10000 > naiveThreshold(4096), so the default path splits.
        var rng = SplitMix64(seed: 77777)
        let vocab = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]
        let a = (0..<100).map { _ in vocab[Int(rng.next() % UInt64(vocab.count))] }
        let b = (0..<100).map { _ in vocab[Int(rng.next() % UInt64(vocab.count))] }

        let ops = Aligner.align(a, b)
        let naiveOps = Aligner.alignNaive(a, b)

        // Equal cost.
        let hCost = Aligner.cost(ops)
        let nCost = Aligner.cost(naiveOps)
        #expect(hCost == nCost)

        // S+D+I == cost.
        let counts = Aligner.opCounts(ops)
        #expect(counts.subs + counts.dels + counts.ins == hCost)

        // Replay validity.
        #expect(replay(ops, a: a, b: b) == b)
    }

    @Test("Hirschberg threshold=1: 100 seeded pairs with cost + replay checks",
          .timeLimit(.minutes(2)))
    func hirschbergThresholdOne() {
        // threshold=1 means the naive base case fires only for m<=1 or n==0,
        // maximising the number of recursive splits.
        var rng = SplitMix64(seed: 54321)
        let vocab = ["one", "two", "three", "four", "five"]

        for _ in 0..<100 {
            let aLen = Int(rng.next() % 41) + 3 // 3-43
            let bLen = Int(rng.next() % 41) + 3
            let a = (0..<aLen).map { _ in vocab[Int(rng.next() % UInt64(vocab.count))] }
            let b = (0..<bLen).map { _ in vocab[Int(rng.next() % UInt64(vocab.count))] }

            let ops = Aligner.align(a, b, naiveThreshold: 1)
            let naiveOps = Aligner.alignNaive(a, b)

            #expect(Aligner.cost(ops) == Aligner.cost(naiveOps),
                    "Cost mismatch for lengths \(aLen),\(bLen)")

            let counts = Aligner.opCounts(ops)
            #expect(counts.subs + counts.dels + counts.ins == Aligner.cost(ops))

            #expect(replay(ops, a: a, b: b) == b)
        }
    }
}
