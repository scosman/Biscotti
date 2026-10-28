import Foundation
import LiveTranscriptionService
import Transcription
import TranscriptionService

// MARK: - Model preparation

extension AppCore {
    /// Gets the models a meeting loads ready in the worker, while no
    /// recording runs, so macOS compiles them in the background instead of
    /// during a meeting. Runs at launch, after onboarding, when the live
    /// transcript is turned on or off, and when its model has downloaded.
    ///
    /// - The live model is kept loaded while the live transcript is on (on
    ///   Macs with more than 8 GiB), so every live start is immediate: macOS
    ///   purges Core ML's compiled-model cache under low disk space, and a
    ///   purged load compiles for one to two minutes. It is loaded at every
    ///   launch, which also repairs a purged cache. With 8 GiB or less, it is
    ///   only prepared, in a run of its own first, so the two Whisper models
    ///   are never loaded together.
    /// - The final pass's Whisper model is prepared once per app and macOS
    ///   build, when its models are on disk.
    func prepareModelsInBackground() async {
        let liveModel = LiveTranscriptionDefaults.whisperModel
        if liveTranscription.canStartLive, Self.keepsLiveModelLoaded(physicalMemory: physicalMemory) {
            transcription.keepModelLoaded(liveModel)
        } else {
            transcription.keepModelLoaded(nil)
            if liveTranscription.canStartLive {
                transcription.prepareModels([liveModel], first: true)
            }
        }
        if await transcription.modelsArePresent() {
            transcription.prepareModels([TranscriptionMethod.current.whisperModel])
        }
    }

    /// Whether this Mac keeps the live model loaded while the live transcript
    /// is on: about 0.2–0.3 GB, most of it wired by the Neural Engine, also
    /// during final passes, on top of large-v3 (the user accepted this on
    /// 25 October 2026).
    public static func keepsLiveModelLoaded(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
        physicalMemory > 8 << 30
    }

    /// The model a recording's live session loads, when it will run one.
    var liveModelForRecording: String? {
        liveTranscription.canStartLive ? LiveTranscriptionDefaults.whisperModel : nil
    }

    /// A language change whose old engine never finished found the worker
    /// stuck in a decode: the queue closes its connection too, so the worker
    /// exits and the live session's next engine starts in a fresh one. The
    /// kept model loads again once the recording stops.
    func resetWorkerWhenLiveFindsItStuck() {
        liveTranscription.onWorkerNeedsReset = { [weak self] in
            await self?.transcription.releaseWorkerIfIdle()
        }
    }

    /// A finished live model download prepares the model, so the next
    /// recording does not wait for macOS to compile it. The new files need
    /// compiling again even if this build prepared the old ones.
    func prepareModelsAfterLiveModelDownloads() {
        liveTranscription.onModelDownloaded = { [weak self] in
            self?.transcription.forgetPreparedModel(LiveTranscriptionDefaults.whisperModel)
            Task { await self?.prepareModelsInBackground() }
        }
    }
}
