import Foundation

/// Encodes and decodes `[Float]` vectors to/from `Data` for SwiftData storage.
/// Uses little-endian Float32, which is the native layout on Apple Silicon.
public enum VectorCoding {
    /// Encodes a vector to little-endian Float32 `Data`.
    public static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    /// Decodes `Data` back to `[Float]`. Returns `nil` if `data.count`
    /// does not equal `dimension * 4`, or if any value is not finite.
    public static func decode(_ data: Data, dimension: Int) -> [Float]? {
        guard data.count == dimension * MemoryLayout<Float>.size else { return nil }
        let vector: [Float] = data.withUnsafeBytes { raw in
            let buffer = raw.bindMemory(to: Float.self)
            return Array(buffer)
        }
        guard vector.allSatisfy(\.isFinite) else { return nil }
        return vector
    }
}
