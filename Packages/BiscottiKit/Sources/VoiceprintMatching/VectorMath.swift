import Accelerate

/// Pure vector operations for voiceprint comparison.
enum VectorMath {
    /// Returns an L2-normalized copy of the vector.
    /// Returns `nil` if the vector is empty, contains a non-finite value, or has zero norm.
    static func normalized(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty else { return nil }
        guard vector.allSatisfy(\.isFinite) else { return nil }

        var sumSquares: Float = 0
        vDSP_dotpr(vector, 1, vector, 1, &sumSquares, vDSP_Length(vector.count))
        let norm = sqrtf(sumSquares)
        guard norm > 0 else { return nil }

        var result = [Float](repeating: 0, count: vector.count)
        var divisor = norm
        vDSP_vsdiv(vector, 1, &divisor, &result, 1, vDSP_Length(vector.count))
        return result
    }

    /// Cosine distance between two **already-normalized** vectors: `clamp(1 - dot, 0, 2)`.
    /// Precondition: both vectors have the same length.
    static func distance(_ lhs: [Float], _ rhs: [Float]) -> Float {
        var dot: Float = 0
        vDSP_dotpr(lhs, 1, rhs, 1, &dot, vDSP_Length(lhs.count))
        return min(2, max(0, 1 - dot))
    }
}
