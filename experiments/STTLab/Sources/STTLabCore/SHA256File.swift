import CryptoKit
import Foundation

/// Streaming SHA-256 hash of a file, read in 1 MB blocks.
public enum SHA256File {
    public static func hex(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = CryptoKit.SHA256()
        let blockSize = 1_048_576 // 1 MB
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: blockSize)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
