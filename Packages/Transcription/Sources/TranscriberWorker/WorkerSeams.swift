import Foundation
import LiveTranscription
import LiveTranscriptModel
import Transcription

/// What `EngineHost` needs from the final-pass engine: the engine, and a way
/// to share its loaded Whisper model with a live session that uses the same
/// model, so Whisper stays warm from the live transcript into the final pass.
public protocol HostedTranscriptionEngine: TranscriptionEngine {
    /// The Whisper model folder name the final pass uses.
    var whisperModel: String { get }

    /// A live decoder on the engine's own Whisper model, loaded if it is not.
    func sharedLiveDecoder() async throws -> any LiveDecoder

    /// Calls `observer` when a model load starts (true) and ends (false);
    /// nil stops it.
    func observeModelLoads(_ observer: (@Sendable (Bool) -> Void)?) async
}

public extension HostedTranscriptionEngine {
    func observeModelLoads(_: (@Sendable (Bool) -> Void)?) async {}
}

extension InProcessTranscriptionEngine: HostedTranscriptionEngine {
    public nonisolated var whisperModel: String {
        whisperModelName
    }

    public func sharedLiveDecoder() async throws -> any LiveDecoder {
        try await WhisperKitLiveDecoder(whisperKit: loadedWhisperKit().whisperKit)
    }
}

/// A live model loaded apart from the final pass's.
public struct LoadedLiveModel: Sendable {
    public let decoder: any LiveDecoder
    /// Releases the model. `EngineHost` calls it once no decode is in flight.
    public let unload: @Sendable () async -> Void

    public init(decoder: any LiveDecoder, unload: @escaping @Sendable () async -> Void) {
        self.decoder = decoder
        self.unload = unload
    }
}

/// Loads a live Whisper model that differs from the final pass's.
public protocol LiveModelLoading: Sendable {
    /// - Throws: `TranscriptionError.needsDownload` when the model is not on disk.
    func load(model: String) async throws -> LoadedLiveModel
}

/// Loads live models from the app's model cache. Never downloads.
public struct LocalWhisperModelLoader: LiveModelLoading {
    public init() {}

    public func load(model: String) async throws -> LoadedLiveModel {
        let decoder = try await WhisperKitLiveDecoder(whisperKit: InProcessTranscriptionEngine.loadLocalWhisperKit(model: model).whisperKit)
        return LoadedLiveModel(decoder: decoder) { await decoder.unloadModels() }
    }
}

/// The connection that started a live session: it receives the session's
/// updates and hears when the worker ends the session on its own.
public protocol LiveSessionOwner: AnyObject, Sendable {
    func deliver(_ update: LiveTrackUpdate)

    /// The session ended without the owner's finish or cancel: a decode
    /// failed, or `cancelActiveWork` ended it.
    func sessionDidEnd(sessionID: UUID, generation: Int)
}

/// Forwards decodes and lets its owner wait until none is in flight.
///
/// A cancelled or timed-out `WhisperLiveSession` returns before the decode it
/// started does. Until that decode returns, the model must not be unloaded
/// and no other work may start on it.
actor TrackedLiveDecoder: LiveDecoder {
    private let decoder: any LiveDecoder
    private var inFlight = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(_ decoder: any LiveDecoder) {
        self.decoder = decoder
    }

    func decode(_ samples: [Float], startTime: TimeInterval, options: LiveDecodeOptions) async throws -> LiveDecodeResult {
        inFlight += 1
        defer { decodeReturned() }
        return try await decoder.decode(samples, startTime: startTime, options: options)
    }

    func waitUntilIdle() async {
        guard inFlight > 0 else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func decodeReturned() {
        inFlight -= 1
        guard inFlight == 0 else { return }
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
    }
}
