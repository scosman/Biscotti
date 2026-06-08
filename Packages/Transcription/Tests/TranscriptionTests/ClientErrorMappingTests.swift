import Foundation
import Testing
@testable import Transcription

@Suite("ClientErrorMapping - InProcess backend")
struct InProcessClientTests {
    @Test("processAudio delegates to stub engine and returns result")
    func inProcessDelegatesToEngine() async throws {
        let stubEngine = StubTranscriptionEngine()
        let expectedResult = makeFixtureResult()
        await stubEngine.setResult(expectedResult)

        let transcriber = Transcriber(
            backend: .inProcess,
            engine: stubEngine
        )

        let result = try await transcriber.processAudio(
            mic: makeAudioURL(),
            system: makeAudioURL()
        )

        #expect(result.transcriptionMethodId == expectedResult.transcriptionMethodId)
        #expect(result.language == "en")
        #expect(result.segments.count == 1)
        #expect(await stubEngine.processAudioCallCount == 1)
    }

    @Test("ensureModelsDownloaded delegates to stub engine")
    func inProcessEnsureModelsDownloaded() async throws {
        let stubEngine = StubTranscriptionEngine()
        let transcriber = Transcriber(
            backend: .inProcess,
            engine: stubEngine
        )

        try await transcriber.ensureModelsDownloaded()

        #expect(await stubEngine.ensureModelsCallCount == 1)
    }

    @Test("ensureModelsDownloaded passes status callback")
    func inProcessEnsureModelsStatus() async throws {
        let stubEngine = StubTranscriptionEngine()
        let transcriber = Transcriber(
            backend: .inProcess,
            engine: stubEngine
        )

        let collector = StatusCollector()
        try await transcriber.ensureModelsDownloaded { value in
            collector.append(value)
        }

        let values = collector.values
        #expect(values.contains("Downloading test model"))
        #expect(values.contains("Models ready"))
    }

    @Test("isAvailable returns true when engine status is ready")
    func inProcessIsAvailableReady() async {
        let stubEngine = StubTranscriptionEngine()
        let transcriber = Transcriber(
            backend: .inProcess,
            engine: stubEngine
        )

        let available = await transcriber.isAvailable()
        #expect(available == true)
    }

    @Test("isAvailable returns false when engine status is not ready")
    func inProcessIsAvailableNotReady() async {
        let stubEngine = StubTranscriptionEngine()
        await stubEngine.setStatus(.needsDownload)
        let transcriber = Transcriber(
            backend: .inProcess,
            engine: stubEngine
        )

        let available = await transcriber.isAvailable()
        #expect(available == false)
    }

    @Test("reTranscribe delegates through processAudio")
    func inProcessReTranscribe() async throws {
        let stubEngine = StubTranscriptionEngine()
        let expectedResult = makeFixtureResult()
        await stubEngine.setResult(expectedResult)

        let transcriber = Transcriber(
            backend: .inProcess,
            engine: stubEngine
        )

        let result = try await transcriber.reTranscribe(
            mic: makeAudioURL(),
            system: makeAudioURL(),
            customVocabulary: ["test"]
        )

        #expect(result.transcriptionMethodId == expectedResult.transcriptionMethodId)
        #expect(await stubEngine.processAudioCallCount == 1)
    }

    @Test("unloadModels delegates to engine")
    func inProcessUnloadModels() async {
        let stubEngine = StubTranscriptionEngine()
        let transcriber = Transcriber(
            backend: .inProcess,
            engine: stubEngine
        )

        await transcriber.unloadModels()

        #expect(await stubEngine.unloadCallCount == 1)
    }

    @Test("statusStream emits current status and updates")
    func inProcessStatusStream() async {
        let stubEngine = StubTranscriptionEngine()
        await stubEngine.setResult(makeFixtureResult())
        let transcriber = Transcriber(
            backend: .inProcess,
            engine: stubEngine
        )

        let stream = await transcriber.statusStream()
        var statuses: [ModelStatus] = []

        // Collect the initial status
        for await status in stream {
            statuses.append(status)
            // After receiving the initial status, trigger an action
            if statuses.count == 1 {
                // Trigger a processAudio which should emit .running then .ready
                Task {
                    _ = try? await transcriber.processAudio(mic: makeAudioURL(), system: makeAudioURL())
                }
            }
            // Collect a few statuses then break
            if statuses.count >= 3 {
                break
            }
        }

        // Should have at least the initial needsDownload + running + ready
        #expect(statuses.count >= 3)
        #expect(statuses[0] == .needsDownload) // initial
        #expect(statuses[1] == .running)
        #expect(statuses[2] == .ready)
    }

    @Test("engine error is mapped and rethrown as TranscriptionError")
    func inProcessEngineErrorMapped() async {
        let stubEngine = StubTranscriptionEngine()
        await stubEngine.setProcessAudioError(
            TranscriptionError.downloadFailed("test download failure")
        )
        let transcriber = Transcriber(
            backend: .inProcess,
            engine: stubEngine
        )

        do {
            _ = try await transcriber.processAudio(mic: makeAudioURL(), system: makeAudioURL())
            Issue.record("Expected error to be thrown")
        } catch {
            let transcriptionError = error as? TranscriptionError
            #expect(transcriptionError == .downloadFailed("test download failure"))
        }
    }

    @Test("non-TranscriptionError from engine is wrapped in transcriptionFailed")
    func inProcessNonTranscriptionErrorWrapped() async {
        let stubEngine = StubTranscriptionEngine()
        await stubEngine.setProcessAudioError(
            NSError(domain: "TestDomain", code: 42, userInfo: [
                NSLocalizedDescriptionKey: "custom error"
            ])
        )
        let transcriber = Transcriber(
            backend: .inProcess,
            engine: stubEngine
        )

        do {
            _ = try await transcriber.processAudio(mic: makeAudioURL(), system: makeAudioURL())
            Issue.record("Expected error to be thrown")
        } catch {
            let transcriptionError = error as? TranscriptionError
            if case let .transcriptionFailed(message) = transcriptionError {
                #expect(message.contains("custom error"))
            } else {
                Issue.record("Expected transcriptionFailed, got \(String(describing: transcriptionError))")
            }
        }
    }
}
