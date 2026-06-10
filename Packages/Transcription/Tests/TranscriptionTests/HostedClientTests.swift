import Foundation
import Testing
@testable import Transcription

@Suite("ClientErrorMapping - Hosted backend (XPC)")
struct HostedClientTests {
    @Test("simulated interruption surfaces workerInterrupted")
    func hostedInterruptionSurfacesWorkerInterrupted() async {
        let stubEngine = StubTranscriptionEngine()
        await stubEngine.setResult(makeFixtureResult())
        let flag = InterruptedFlag()
        let transcriber = Transcriber(
            backend: .hosted(serviceName: "test.service"),
            engine: stubEngine,
            interruptedFlag: flag
        )

        // Simulate worker crash
        flag.value = true

        do {
            _ = try await transcriber.processAudio(mic: makeAudioURL(), system: makeAudioURL())
            Issue.record("Expected workerInterrupted error")
        } catch {
            #expect(error as? TranscriptionError == .workerInterrupted)
        }
    }

    @Test("after workerInterrupted, next call succeeds (retriable)")
    func hostedInterruptionIsRetriable() async throws {
        let stubEngine = StubTranscriptionEngine()
        await stubEngine.setResult(makeFixtureResult())
        let flag = InterruptedFlag()
        let transcriber = Transcriber(
            backend: .hosted(serviceName: "test.service"),
            engine: stubEngine,
            interruptedFlag: flag
        )

        // First: simulate interruption
        flag.value = true
        do {
            _ = try await transcriber.processAudio(mic: makeAudioURL(), system: makeAudioURL())
            Issue.record("Expected workerInterrupted error")
        } catch {
            #expect(error as? TranscriptionError == .workerInterrupted)
        }

        // Second: flag was cleared, next call should succeed
        let result = try await transcriber.processAudio(mic: makeAudioURL(), system: makeAudioURL())
        #expect(result.language == "en")
        #expect(await stubEngine.processAudioCallCount == 1) // Only the successful call
    }

    @Test("interrupted flag blocks ensureModelsDownloaded too")
    func hostedInterruptionBlocksDownload() async {
        let stubEngine = StubTranscriptionEngine()
        let flag = InterruptedFlag()
        let transcriber = Transcriber(
            backend: .hosted(serviceName: "test.service"),
            engine: stubEngine,
            interruptedFlag: flag
        )

        flag.value = true

        do {
            try await transcriber.ensureModelsDownloaded()
            Issue.record("Expected workerInterrupted error")
        } catch {
            #expect(error as? TranscriptionError == .workerInterrupted)
        }
    }

    @Test("engine error passes through via hosted backend")
    func hostedEngineErrorPassesThrough() async {
        let stubEngine = StubTranscriptionEngine()
        await stubEngine.setProcessAudioError(
            TranscriptionError.modelLoadFailed("GPU not available")
        )
        let transcriber = Transcriber(
            backend: .hosted(serviceName: "test.service"),
            engine: stubEngine
        )

        do {
            _ = try await transcriber.processAudio(mic: makeAudioURL(), system: makeAudioURL())
            Issue.record("Expected error")
        } catch {
            #expect(error as? TranscriptionError == .modelLoadFailed("GPU not available"))
        }
    }

    @Test("unloadModels delegates through hosted backend")
    func hostedUnloadModels() async {
        let stubEngine = StubTranscriptionEngine()
        let transcriber = Transcriber(
            backend: .hosted(serviceName: "test.service"),
            engine: stubEngine
        )

        await transcriber.unloadModels()

        #expect(await stubEngine.unloadCallCount == 1)
    }

    @Test("isAvailable returns false when interrupted")
    func hostedIsAvailableWhenInterrupted() async {
        let stubEngine = StubTranscriptionEngine()
        let flag = InterruptedFlag()
        let mockConnection = MockXPCConnection()
        let transcriber = Transcriber(
            backend: .hosted(serviceName: "test.service"),
            engine: stubEngine,
            xpcConnection: mockConnection,
            interruptedFlag: flag
        )

        flag.value = true

        let available = await transcriber.isAvailable()
        #expect(available == false)
    }

    @Test("isAvailable returns false when no XPC connection")
    func hostedIsAvailableNoConnection() async {
        let stubEngine = StubTranscriptionEngine()
        let transcriber = Transcriber(
            backend: .hosted(serviceName: "test.service"),
            engine: stubEngine,
            xpcConnection: nil,
            interruptedFlag: InterruptedFlag()
        )

        let available = await transcriber.isAvailable()
        #expect(available == false)
    }

    @Test("isAvailable returns false when proxy is nil")
    func hostedIsAvailableNilProxy() async {
        let stubEngine = StubTranscriptionEngine()
        let mockConnection = MockXPCConnection()
        mockConnection.proxy = nil
        let transcriber = Transcriber(
            backend: .hosted(serviceName: "test.service"),
            engine: stubEngine,
            xpcConnection: mockConnection,
            interruptedFlag: InterruptedFlag()
        )

        let available = await transcriber.isAvailable()
        #expect(available == false)
    }
}

@Suite("XPCEngineAdapter")
struct XPCEngineAdapterTests {
    @Test("throws workerUnavailable when proxy is nil")
    func unavailableProxy() async {
        let adapter = XPCEngineAdapter(proxyProvider: { nil })

        do {
            _ = try await adapter.processAudio(
                micPath: "/tmp/mic.wav", systemPath: "/tmp/system.wav", customVocabulary: []
            )
            Issue.record("Expected workerUnavailable")
        } catch {
            #expect(error as? TranscriptionError == .workerUnavailable)
        }
    }

    @Test("ensureModelsDownloaded throws workerUnavailable when proxy is nil")
    func ensureModelsUnavailable() async {
        let adapter = XPCEngineAdapter(proxyProvider: { nil })

        do {
            try await adapter.ensureModelsDownloaded(status: { _ in })
            Issue.record("Expected workerUnavailable")
        } catch {
            #expect(error as? TranscriptionError == .workerUnavailable)
        }
    }

    @Test("status returns .ready (XPC adapter cannot query worker status)")
    func statusReturnsReady() async {
        let adapter = XPCEngineAdapter(proxyProvider: { nil })

        let status = await adapter.status()
        #expect(status == .ready)
    }
}

@Suite("XPCEngineAdapter - Round-trip")
struct XPCEngineAdapterRoundTripTests {
    @Test("processAudio round-trips request through mock service and returns result")
    func processAudioRoundTrip() async throws {
        let mockService = MockTranscriberService()
        let expectedResult = makeFixtureResult(transcriptionMethodId: "round-trip-method")
        mockService.processAudioResult = expectedResult

        let adapter = XPCEngineAdapter(proxyProvider: { mockService })

        let result = try await adapter.processAudio(
            micPath: "/tmp/mic.wav",
            systemPath: "/tmp/system.wav",
            customVocabulary: ["Biscotti", "WhisperKit"]
        )

        // Verify the result round-tripped correctly
        #expect(result.transcriptionMethodId == "round-trip-method")
        #expect(result.language == "en")
        #expect(result.segments.count == 1)
        #expect(result.segments[0].text == "Hello world")

        // Verify the request was correctly encoded and decoded by the mock
        let receivedRequest = mockService.lastProcessRequest
        #expect(receivedRequest != nil)
        #expect(receivedRequest?.micPath == "/tmp/mic.wav")
        #expect(receivedRequest?.systemPath == "/tmp/system.wav")
        #expect(receivedRequest?.customVocabulary == ["Biscotti", "WhisperKit"])
    }

    @Test("unloadModels round-trips through mock service")
    func unloadModelsRoundTrip() async {
        let mockService = MockTranscriberService()
        let adapter = XPCEngineAdapter(proxyProvider: { mockService })

        await adapter.unloadModels()

        #expect(mockService.unloadCallCount == 1)
    }

    @Test("processAudio maps XPC interrupted error (code 4097) to workerInterrupted")
    func processAudioMapsInterruptedError() async {
        let mockService = MockTranscriberService()
        mockService.processAudioError = NSError(
            domain: NSCocoaErrorDomain, code: 4097, userInfo: nil
        )
        let adapter = XPCEngineAdapter(proxyProvider: { mockService })

        do {
            _ = try await adapter.processAudio(
                micPath: "/tmp/mic.wav", systemPath: "/tmp/system.wav", customVocabulary: []
            )
            Issue.record("Expected workerInterrupted")
        } catch {
            #expect(error as? TranscriptionError == .workerInterrupted)
        }
    }

    @Test("processAudio maps XPC invalid error (code 4099) to workerUnavailable")
    func processAudioMapsInvalidError() async {
        let mockService = MockTranscriberService()
        mockService.processAudioError = NSError(
            domain: NSCocoaErrorDomain, code: 4099, userInfo: nil
        )
        let adapter = XPCEngineAdapter(proxyProvider: { mockService })

        do {
            _ = try await adapter.processAudio(
                micPath: "/tmp/mic.wav", systemPath: "/tmp/system.wav", customVocabulary: []
            )
            Issue.record("Expected workerUnavailable")
        } catch {
            #expect(error as? TranscriptionError == .workerUnavailable)
        }
    }

    @Test("processAudio maps non-XPC NSCocoaErrorDomain to transcriptionFailed")
    func processAudioMapsNonXPCCocoaError() async {
        let mockService = MockTranscriberService()
        // A decoding error (code 4864) is NSCocoaErrorDomain but NOT an XPC connection code
        mockService.processAudioError = NSError(
            domain: NSCocoaErrorDomain, code: 4864,
            userInfo: [NSLocalizedDescriptionKey: "decoding failure"]
        )
        let adapter = XPCEngineAdapter(proxyProvider: { mockService })

        do {
            _ = try await adapter.processAudio(
                micPath: "/tmp/mic.wav", systemPath: "/tmp/system.wav", customVocabulary: []
            )
            Issue.record("Expected transcriptionFailed")
        } catch {
            if case let .transcriptionFailed(message) = error as? TranscriptionError {
                #expect(message.contains("decoding failure"))
            } else {
                Issue.record("Expected transcriptionFailed, got \(error)")
            }
        }
    }

    @Test("ensureModelsDownloaded maps XPC interrupted error to workerInterrupted")
    func ensureModelsMapsInterruptedError() async {
        let mockService = MockTranscriberService()
        mockService.ensureModelsError = NSError(
            domain: NSCocoaErrorDomain, code: 4097, userInfo: nil
        )
        let adapter = XPCEngineAdapter(proxyProvider: { mockService })

        do {
            try await adapter.ensureModelsDownloaded(status: { _ in })
            Issue.record("Expected workerInterrupted")
        } catch {
            #expect(error as? TranscriptionError == .workerInterrupted)
        }
    }
}

@Suite("InterruptedFlag")
struct InterruptedFlagTests {
    @Test("initial value is false")
    func initialValueFalse() {
        let flag = InterruptedFlag()
        #expect(flag.value == false)
    }

    @Test("value can be set and read")
    func setAndRead() {
        let flag = InterruptedFlag()
        flag.value = true
        #expect(flag.value == true)
        flag.value = false
        #expect(flag.value == false)
    }
}
