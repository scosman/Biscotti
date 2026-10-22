/// An edit operation in the alignment of two token sequences.
public enum EditOp: Equatable, Sendable {
    /// Both tokens match (indices in a and b).
    case match(Int, Int)
    /// Substitution (indices in a and b).
    case sub(Int, Int)
    /// Deletion: token at index in a is missing from b.
    case del(Int)
    /// Insertion: extra token at index in b.
    case ins(Int)
}

/// Edit-distance alignment of two string sequences. Costs: match=0, sub=1, del=1, ins=1.
/// Tie order in backtrace: diagonal (match/sub) before deletion before insertion.
///
/// Uses Hirschberg (linear memory) for large inputs, falling back to the full-matrix DP
/// for moderate inputs to preserve exact tie-breaking consistency.
public enum Aligner {

    // MARK: - Public API

    /// Hirschberg alignment (linear memory for large inputs). Returns the edit script.
    public static func align(_ a: [String], _ b: [String]) -> [EditOp] {
        align(a, b, naiveThreshold: naiveThreshold)
    }

    /// Alignment with a caller-chosen naive threshold. Internal — exposed for tests
    /// that need to force the Hirschberg recursive-split path on small inputs.
    static func align(_ a: [String], _ b: [String], naiveThreshold threshold: Int) -> [EditOp] {
        var table: [String: Int] = [:]
        var nextID = 0
        func intern(_ s: String) -> Int {
            if let id = table[s] { return id }
            let id = nextID
            table[s] = id
            nextID += 1
            return id
        }
        let ai = a.map { intern($0) }
        let bi = b.map { intern($0) }
        return hirschberg(ai, 0, ai.count, bi, 0, bi.count, naiveThreshold: threshold)
    }

    /// Naive full-matrix alignment (for testing). Returns the edit script.
    static func alignNaive(_ a: [String], _ b: [String]) -> [EditOp] {
        var table: [String: Int] = [:]
        var nextID = 0
        func intern(_ s: String) -> Int {
            if let id = table[s] { return id }
            let id = nextID
            table[s] = id
            nextID += 1
            return id
        }
        let ai = a.map { intern($0) }
        let bi = b.map { intern($0) }
        return naiveDP(ai, 0, ai.count, bi, 0, bi.count)
    }

    // MARK: - Hirschberg

    /// The full-matrix DP threshold. Below this product, the naive DP handles the
    /// sub-problem directly (preserving exact tie-breaking). Above it, Hirschberg
    /// splits for linear memory. 4096 ~= 64x64, well within memory budget.
    private static let naiveThreshold = 4096

    /// Recursive Hirschberg on interned token arrays.
    /// `a[aLo..<aHi]` aligned against `b[bLo..<bHi]`.
    private static func hirschberg(_ a: [Int], _ aLo: Int, _ aHi: Int,
                                   _ b: [Int], _ bLo: Int, _ bHi: Int,
                                   naiveThreshold threshold: Int) -> [EditOp] {
        let m = aHi - aLo
        let n = bHi - bLo

        // Base case: use the full-matrix DP when the sub-problem is small enough.
        if m * n <= threshold || m <= 1 || n == 0 {
            return naiveDP(a, aLo, aHi, b, bLo, bHi)
        }

        let aMid = aLo + m / 2

        // Forward last row: align a[aLo..<aMid] vs b[bLo..<bHi].
        let fwd = lastRow(a, aLo, aMid, b, bLo, bHi, forward: true)
        // Reverse last row: align a[aMid..<aHi] vs b[bLo..<bHi].
        let rev = lastRow(a, aMid, aHi, b, bLo, bHi, forward: false)

        // Find optimal split in b (smallest j among tied minimums).
        var bestJ = bLo
        var bestCost = Int32.max
        for j in bLo...bHi {
            let cost = fwd[j - bLo] + rev[n - (j - bLo)]
            if cost < bestCost {
                bestCost = cost
                bestJ = j
            }
        }

        // Recurse on both halves and concatenate.
        let left = hirschberg(a, aLo, aMid, b, bLo, bestJ, naiveThreshold: threshold)
        let right = hirschberg(a, aMid, aHi, b, bestJ, bHi, naiveThreshold: threshold)
        return left + right
    }

    /// Compute the last row of the DP matrix (linear memory).
    /// If forward: aligns a[aLo..<aHi] vs b[bLo..<bHi] left to right.
    /// If reverse: aligns both reversed, right to left.
    /// Returns an array of length (bHi - bLo + 1).
    private static func lastRow(_ a: [Int], _ aLo: Int, _ aHi: Int,
                                _ b: [Int], _ bLo: Int, _ bHi: Int,
                                forward: Bool) -> [Int32] {
        let m = aHi - aLo
        let n = bHi - bLo

        var prev = [Int32](repeating: 0, count: n + 1)
        var curr = [Int32](repeating: 0, count: n + 1)

        // Initialize first row: all insertions.
        for j in 0...n { prev[j] = Int32(j) }

        guard m > 0 else { return prev }

        for i in 1...m {
            curr[0] = Int32(i)
            let ai = forward ? a[aLo + i - 1] : a[aHi - i]
            for j in 1...n {
                let bj = forward ? b[bLo + j - 1] : b[bHi - j]
                let diagCost = prev[j - 1] + (ai == bj ? 0 : 1)
                let delCost = prev[j] + 1
                let insCost = curr[j - 1] + 1
                curr[j] = min(diagCost, delCost, insCost)
            }
            swap(&prev, &curr)
        }

        return prev
    }

    // MARK: - Naive full-matrix DP

    /// Full-matrix DP on interned tokens. Returns the edit script with absolute indices.
    private static func naiveDP(_ a: [Int], _ aLo: Int, _ aHi: Int,
                                _ b: [Int], _ bLo: Int, _ bHi: Int) -> [EditOp] {
        let m = aHi - aLo
        let n = bHi - bLo

        // Edge cases: one or both sequences empty.
        if m == 0 && n == 0 { return [] }
        if m == 0 {
            return (0..<n).map { .ins(bLo + $0) }
        }
        if n == 0 {
            return (0..<m).map { .del(aLo + $0) }
        }

        // Build the cost matrix.
        var dp = [[Int32]](repeating: [Int32](repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = Int32(i) }
        for j in 0...n { dp[0][j] = Int32(j) }

        for i in 1...m {
            for j in 1...n {
                let eq = a[aLo + i - 1] == b[bLo + j - 1]
                let diagCost = dp[i - 1][j - 1] + (eq ? 0 : 1)
                let delCost = dp[i - 1][j] + 1
                let insCost = dp[i][j - 1] + 1
                dp[i][j] = min(diagCost, delCost, insCost)
            }
        }

        // Backtrace. Tie order: diagonal > deletion > insertion.
        var ops: [EditOp] = []
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0 && j > 0 {
                let eq = a[aLo + i - 1] == b[bLo + j - 1]
                let diagCost = dp[i - 1][j - 1] + (eq ? 0 : 1)
                if dp[i][j] == diagCost {
                    let ai = aLo + i - 1
                    let bj = bLo + j - 1
                    ops.append(eq ? .match(ai, bj) : .sub(ai, bj))
                    i -= 1
                    j -= 1
                    continue
                }
            }
            if i > 0 && dp[i][j] == dp[i - 1][j] + 1 {
                ops.append(.del(aLo + i - 1))
                i -= 1
            } else {
                ops.append(.ins(bLo + j - 1))
                j -= 1
            }
        }

        ops.reverse()
        return ops
    }
}

// MARK: - Helpers

extension Aligner {

    /// Total edit distance from an op list.
    public static func cost(_ ops: [EditOp]) -> Int {
        ops.reduce(0) { sum, op in
            switch op {
            case .match: return sum
            case .sub, .del, .ins: return sum + 1
            }
        }
    }

    /// Count each op type.
    public static func opCounts(_ ops: [EditOp]) -> (matches: Int, subs: Int, dels: Int, ins: Int) {
        var m = 0, s = 0, d = 0, n = 0
        for op in ops {
            switch op {
            case .match: m += 1
            case .sub: s += 1
            case .del: d += 1
            case .ins: n += 1
            }
        }
        return (m, s, d, n)
    }
}
