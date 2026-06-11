import Foundation
@testable import Transcription

// MARK: - Stub Engine

/// A stub `TranscriptionEngine` for testing the `Transcriber` actor.
/// Configurable: set `processAudioResult` / `processAudioError` etc. to
/// control what the engine returns or throws.
actor StubTranscriptionEngine: TranscriptionEngine {
    var processAudioResult: TranscriptResult?
    var processAudioError: (any Error)?
    var ensureModelsError: (any Error)?
    var currentStatus: ModelStatus = .ready
    var processAudioCallCount = 0
    var ensureModelsCallCount = 0
    var unloadCallCount = 0

    func ensureModelsDownloaded(status: @escaping @Sendable (String) -> Void) async throws {
        ensureModelsCallCount += 1
        if let error = ensureModelsError { throw error }
        status("Downloading test model")
        status("Models ready")
    }

    func processAudio(
        micPath _: String,
        systemPath _: String,
        customVocabulary _: [String]
    ) async throws -> TranscriptResult {
        processAudioCallCount += 1
        if let error = processAudioError { throw error }
        guard let result = processAudioResult else {
            throw TranscriptionError.invalidInput("No result configured in stub")
        }
        return result
    }

    func unloadModels() async {
        unloadCallCount += 1
        currentStatus = .needsDownload
    }

    func status() async -> ModelStatus {
        currentStatus
    }

    func setResult(_ result: TranscriptResult) {
        processAudioResult = result
    }

    func setProcessAudioError(_ error: any Error) {
        processAudioError = error
    }

    func setStatus(_ status: ModelStatus) {
        currentStatus = status
    }
}

// MARK: - Mock XPC Connection

/// A mock XPC connection seam that simulates various XPC behaviors.
final class MockXPCConnection: TranscriberXPCConnecting, @unchecked Sendable {
    var proxy: (any TranscriberServiceProtocol)?
    var interruptionHandler: (@Sendable () -> Void)?
    var invalidationHandler: (@Sendable () -> Void)?
    var statusHandler: (@Sendable (String) -> Void)?
    var activateCalled = false
    var invalidateCalled = false

    func remoteObjectProxy() -> (any TranscriberServiceProtocol)? {
        proxy
    }

    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {
        interruptionHandler = handler
    }

    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        invalidationHandler = handler
    }

    func setStatusHandler(_ handler: (@Sendable (String) -> Void)?) {
        statusHandler = handler
    }

    func activate() {
        activateCalled = true
    }

    func invalidate() {
        invalidateCalled = true
    }

    /// Simulate a worker crash/interruption.
    func simulateInterruption() {
        interruptionHandler?()
    }
}

// MARK: - Test Helpers

/// A fixture `TranscriptResult` for tests.
func makeFixtureResult(transcriptionMethodId: String = "v1") -> TranscriptResult {
    TranscriptResult(
        transcriptionMethodId: transcriptionMethodId,
        language: "en",
        speakerCount: 1,
        segments: [
            TranscriptSegment(
                speakerID: 0,
                speakerLabel: "Speaker 0",
                startTime: 0.0,
                endTime: 1.0,
                text: "Hello world",
                confidence: 0.0,
                noSpeechProbability: 0.0,
                words: nil
            )
        ],
        speakerEmbeddings: [:],
        processingDuration: 0.5
    )
}

func makeAudioURL() -> URL {
    URL(fileURLWithPath: "/tmp/test-audio.wav")
}

// MARK: - CallCounter

/// Thread-safe counter for tracking factory/callback invocations in @Sendable closures.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock()
        _value += 1
        lock.unlock()
    }
}

// MARK: - StatusCollector

/// Thread-safe collector for status messages in @Sendable closures.
final class StatusCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _values
    }

    func append(_ value: String) {
        lock.lock()
        _values.append(value)
        lock.unlock()
    }
}

// MARK: - Mock TranscriberServiceProtocol

/// A mock `TranscriberServiceProtocol` that decodes the real XPC request payloads,
/// records what it received, and replies with a configurable `TranscriptResult`.
/// Used to test XPCEngineAdapter end-to-end (encoding/decoding round-trip).
final class MockTranscriberService: TranscriberServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()

    /// The most recent `XPCProcessRequest` received by `processAudio`.
    private var _lastProcessRequest: XPCProcessRequest?
    var lastProcessRequest: XPCProcessRequest? {
        lock.lock()
        defer { lock.unlock() }
        return _lastProcessRequest
    }

    /// The result to return from `processAudio`.
    var processAudioResult: TranscriptResult?

    /// An error to return from `processAudio` (takes precedence over result).
    var processAudioError: Error?

    /// An error to return from `ensureModelsDownloaded`.
    var ensureModelsError: Error?

    /// Count of `unloadModels` calls.
    private var _unloadCallCount = 0
    var unloadCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _unloadCallCount
    }

    func processAudio(
        requestData: Data,
        reply: @escaping @Sendable (Data?, Error?) -> Void
    ) {
        do {
            let request = try JSONDecoder().decode(XPCProcessRequest.self, from: requestData)
            lock.lock()
            _lastProcessRequest = request
            lock.unlock()
        } catch {
            reply(nil, error)
            return
        }

        if let error = processAudioError {
            reply(nil, error)
            return
        }

        guard let result = processAudioResult else {
            reply(nil, NSError(
                domain: "MockError", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No result configured"]
            ))
            return
        }

        do {
            let data = try JSONEncoder().encode(result)
            reply(data, nil)
        } catch {
            reply(nil, error)
        }
    }

    func ensureModelsDownloaded(
        reply: @escaping @Sendable (Error?) -> Void
    ) {
        reply(ensureModelsError)
    }

    func unloadModels(reply: @escaping @Sendable () -> Void) {
        lock.lock()
        _unloadCallCount += 1
        lock.unlock()
        reply()
    }

    func healthCheck(reply: @escaping @Sendable (Bool) -> Void) {
        reply(true)
    }
}
