import AudioImport
import Foundation

/// Scriptable fake converter for tests. Records calls and writes dummy bytes
/// to the destination so file moves succeed.
public final class FakeAudioConverter: AudioConverting, @unchecked Sendable {
    /// Per-source-filename scripted outcome; default success (60s, 128 KB).
    public var outcomes: [String: Result<ConversionResult, ImportFailure>] = [:]

    /// If set, convert awaits this continuation before finishing (to observe
    /// `.converting` status).
    public var gate: CheckedContinuation<Void, Never>?

    /// Sources that were passed to `convert`.
    public private(set) var convertedSources: [URL] = []

    public init() {}

    public func convert(
        source: URL, destination: URL
    ) async throws -> ConversionResult {
        convertedSources.append(source)

        if let gate {
            await withCheckedContinuation { (inner: CheckedContinuation<Void, Never>) in
                // The test resumes this by calling the stored continuation.
                inner.resume()
            }
            _ = gate // Silence the unused warning -- the gate is consumed externally.
        }

        let key = source.lastPathComponent
        let outcome = outcomes[key] ?? .success(
            ConversionResult(duration: 60.0, byteSize: 131_072)
        )

        switch outcome {
        case let .success(result):
            // Write dummy bytes so moves succeed.
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(repeating: 0xFF, count: 64).write(to: destination)
            return result
        case let .failure(failure):
            throw failure
        }
    }
}
