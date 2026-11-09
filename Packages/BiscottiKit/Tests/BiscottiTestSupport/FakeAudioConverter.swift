import AudioImport
import Foundation

/// Scriptable fake converter for tests. Records calls and writes dummy bytes
/// to the destination so file moves succeed.
public final class FakeAudioConverter: AudioConverting, @unchecked Sendable {
    /// Per-source-filename scripted outcome; default success (60s, 128 KB).
    public var outcomes: [String: Result<ConversionResult, ImportFailure>] = [:]

    /// Sources that were passed to `convert`.
    public private(set) var convertedSources: [URL] = []

    /// Block that `convert` awaits before returning. Set via `installGate()`.
    private var gateBlock: (@Sendable () async -> Void)?

    public init() {}

    /// Installs a gate that pauses the next `convert` call so the test can
    /// observe `.converting` status.
    ///
    /// Returns a pair:
    /// - `entered`: awaitable; completes when `convert` reaches the gate.
    /// - `resume`: call to release the gate and let `convert` finish.
    ///
    /// The gate is consumed by one `convert` call; subsequent calls proceed
    /// immediately unless another gate is installed.
    public func installGate() -> (
        entered: @Sendable () async -> Void,
        resume: @Sendable () -> Void
    ) {
        let (enteredStream, enteredCont) = AsyncStream<Void>.makeStream()
        let (resumeStream, resumeCont) = AsyncStream<Void>.makeStream()

        gateBlock = { @Sendable in
            enteredCont.yield()
            enteredCont.finish()
            for await _ in resumeStream {}
        }

        return (
            entered: { @Sendable in
                for await _ in enteredStream {}
            },
            resume: { @Sendable in
                resumeCont.finish()
            }
        )
    }

    public func convert(
        source: URL, destination: URL
    ) async throws -> ConversionResult {
        convertedSources.append(source)

        if let block = gateBlock {
            gateBlock = nil
            await block()
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
