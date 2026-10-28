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
        public var shutdownCalled = false
        public var modelsPresentCalled = false
        public var lastMicURL: URL?
        public var lastSystemURL: URL?
        public var lastVocabulary: [String]?

        /// Number of times `ensureModelsDownloaded` has been called.
        public var ensureModelsCallCount = 0

        /// Number of times `shutdown` has been called.
        public var shutdownCallCount = 0

        /// `shutdownCallCount` when the last `processAudio` began.
        public var shutdownCountAtProcessAudio: Int?

        /// Number of times `modelsPresent` has been called.
        public var modelsPresentCallCount = 0

        /// Number of times `cancelActiveWork` has been called.
        public var cancelActiveWorkCallCount = 0

        /// The model lists `prepareModels` received; each is prepared at once.
        public var preparationRequests: [[String]] = []

        /// The model each request asked to keep loaded, in the same order.
        public var keptLoaded: [String?] = []

        /// Number of times `unloadFinalPassModels` has been called.
        public var unloadFinalPassModelsCallCount = 0

        /// Whether each request asked to load the kept model again, in the same order.
        public var reloadedKept: [Bool] = []

        /// The handler `observeWorkerInterruptions` received; a test calls it to report a crash.
        public var interruptionHandler: (@Sendable () -> Void)?

        /// The handler `observeModelLoads` received; a test calls it to report a load.
        public var modelLoadHandler: (@Sendable (Bool) -> Void)?

        /// While set, `processAudio` waits for `finishPass()`.
        public var holdsPasses = false
        var passWaiter: CheckedContinuation<Void, Never>?

        /// Error to throw from `ensureModelsDownloaded`, if any.
        public var ensureModelsError: (any Error)?

        /// Error to throw from `processAudio`, if any.
        public var processAudioError: (any Error)?

        /// The canned result to return from `processAudio`.
        public var cannedResult: TranscriptResult

        /// Status messages to emit during `ensureModelsDownloaded`.
        public var statusMessages: [String]

        /// The value returned by `modelsPresent()`. Defaults to `true`
        /// (models present on disk) to match the common test scenario.
        public var modelsPresentResult: Bool = true

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
        backing.ensureModelsCallCount += 1
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
        backing.shutdownCountAtProcessAudio = backing.shutdownCallCount
        backing.lastMicURL = mic
        backing.lastSystemURL = system
        backing.lastVocabulary = customVocabulary
        if backing.holdsPasses {
            await withCheckedContinuation { backing.passWaiter = $0 }
        }
        if let error = backing.processAudioError {
            throw error
        }
        return backing.cannedResult
    }

    public func modelsPresent() async -> Bool {
        backing.modelsPresentCalled = true
        backing.modelsPresentCallCount += 1
        return backing.modelsPresentResult
    }

    public func cancelActiveWork() async {
        backing.cancelActiveWorkCallCount += 1
    }

    public func waitUntilWorkerIdle() async {}

    public func prepareModels(_ models: [String], keepLoaded: String?, reloadingKept: Bool) async throws -> [String] {
        backing.preparationRequests.append(models)
        backing.keptLoaded.append(keepLoaded)
        backing.reloadedKept.append(reloadingKept)
        return models
    }

    public func unloadFinalPassModels() async {
        backing.unloadFinalPassModelsCallCount += 1
    }

    public func observeModelLoads(_ handler: @escaping @Sendable (Bool) -> Void) async {
        backing.modelLoadHandler = handler
    }

    /// Lets a held pass return.
    public func finishPass() {
        backing.passWaiter?.resume()
        backing.passWaiter = nil
    }

    public var isHoldingPass: Bool {
        backing.passWaiter != nil
    }

    public func observeWorkerInterruptions(_ handler: @escaping @Sendable () -> Void) async {
        backing.interruptionHandler = handler
    }

    public func shutdown() async {
        backing.shutdownCalled = true
        backing.shutdownCallCount += 1
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
        processingDuration: 3.5
    )
}
