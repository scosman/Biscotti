import BiscottiTestSupport
import DataStore
import Foundation
import Testing
import Transcription
import Vocabulary
@testable import TranscriptionService

@Suite("TranscriptionService -- worker retry errors")
@MainActor
struct WorkerRetryErrorTests {
    @Test(
        "A busy worker, a stopped pass and an interrupted worker are retriable, each with its own message",
        arguments: [
            (TranscriptionError.workerBusy, "The transcription worker was busy. Tap Retry."),
            (TranscriptionError.cancelled, "Transcription stopped before it finished. Tap Retry."),
            (TranscriptionError.workerInterrupted, "Transcription worker stopped unexpectedly. Tap Retry.")
        ]
    )
    func retryMessages(error: TranscriptionError, message: String) throws {
        let store = try DataStore(storage: .inMemory)
        let service = TranscriptionService(store: store, engine: FakeTranscriber(), vocabulary: VocabularyService(store: store))

        let mapped = service.mapEngineError(error)

        #expect(mapped.message == message)
        #expect(mapped.retriable)
    }

    @Test("A pass the worker stopped before it finished fails as retriable")
    func stoppedPassFailsAsRetriable() async throws {
        let store = try DataStore(storage: .inMemory)
        let engine = FakeTranscriber(processAudioError: TranscriptionError.cancelled)
        let service = TranscriptionService(store: store, engine: engine, vocabulary: VocabularyService(store: store))
        let meetingID = try await store.createMeeting(title: "Stopped Pass")
        try await store.attachAudio([
            AudioFileRef(role: .mic, path: "/tmp/test/mic.aac", byteSize: 1024, isPresent: true),
            AudioFileRef(role: .system, path: "/tmp/test/system.aac", byteSize: 2048, isPresent: true)
        ], to: meetingID)

        await service.transcribe(meetingID: meetingID)

        #expect(service.jobs[meetingID] == .failed(message: "Transcription stopped before it finished. Tap Retry.", retriable: true))
    }
}
