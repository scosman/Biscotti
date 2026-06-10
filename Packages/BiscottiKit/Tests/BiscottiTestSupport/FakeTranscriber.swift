import Foundation
import Transcription
import TranscriptionService

/// A configurable fake `Transcribing` for tests.
///
/// Uses a reference-type backing store so mutations are visible through
/// protocol existentials. The backing store is `@unchecked Sendable` --
/// all access is confined to `@MainActor` test functions in practice.
public struct FakeTranscriber: Transcribing, @unchecked Sendable {
    public final class Backing: @unchecked Sendable {
        public var ensureModelsCalled = false
        public var processAudioCalled = false
        public var lastMicURL: URL?
        public var lastSystemURL: URL?
        public var lastVocabulary: [String]?

        /// Error to throw from `ensureModelsDownloaded`, if any.
        public var ensureModelsError: (any Error)?

        /// Error to throw from `processAudio`, if any.
        public var processAudioError: (any Error)?

        /// The canned result to return from `processAudio`.
        public var cannedResult: TranscriptResult

        /// Status messages to emit during `ensureModelsDownloaded`.
        public var statusMessages: [String]

        public init(
            cannedResult: TranscriptResult,
            ensureModelsError: (any Error)? = nil,
            processAudioError: (any Error)? = nil,
            statusMessages: [String] = []
        ) {
            self.cannedResult = cannedResult
            self.ensureModelsError = ensureModelsError
            self.processAudioError = processAudioError
            self.statusMessages = statusMessages
        }
    }

    public let backing: Backing

    public init(
        cannedResult: TranscriptResult? = nil,
        ensureModelsError: (any Error)? = nil,
        processAudioError: (any Error)? = nil,
        statusMessages: [String] = []
    ) {
        backing = Backing(
            cannedResult: cannedResult ?? FakeTranscriber.defaultResult,
            ensureModelsError: ensureModelsError,
            processAudioError: processAudioError,
            statusMessages: statusMessages
        )
    }

    public func ensureModelsDownloaded(
        status: (@Sendable (String) -> Void)?
    ) async throws {
        backing.ensureModelsCalled = true
        for message in backing.statusMessages {
            status?(message)
        }
        if let error = backing.ensureModelsError {
            throw error
        }
    }

    public func processAudio(
        mic: URL,
        system: URL,
        customVocabulary: [String]
    ) async throws -> TranscriptResult {
        backing.processAudioCalled = true
        backing.lastMicURL = mic
        backing.lastSystemURL = system
        backing.lastVocabulary = customVocabulary
        if let error = backing.processAudioError {
            throw error
        }
        return backing.cannedResult
    }

    /// Deterministic UUIDs for test assertions.
    private static let resultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        ?? UUID()
    private static let segment0ID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")
        ?? UUID()
    private static let segment1ID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")
        ?? UUID()

    /// A minimal valid `TranscriptResult` for tests.
    public static let defaultResult = TranscriptResult(
        id: resultID,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        transcriptionMethodId: "v1",
        language: "en",
        speakerCount: 2,
        segments: [
            TranscriptSegment(
                id: segment0ID,
                speakerID: 0,
                speakerLabel: "Speaker 0",
                startTime: 0.0,
                endTime: 5.0,
                text: "Hello, how are you?",
                confidence: 0.95,
                noSpeechProbability: 0.01,
                words: nil
            ),
            TranscriptSegment(
                id: segment1ID,
                speakerID: 1,
                speakerLabel: "Speaker 1",
                startTime: 5.0,
                endTime: 10.0,
                text: "I'm doing well, thanks.",
                confidence: 0.92,
                noSpeechProbability: 0.02,
                words: nil
            )
        ],
        speakerEmbeddings: [:],
        processingDuration: 3.5
    )
}
