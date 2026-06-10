import AudioCapture
import Foundation

/// Seam over `AudioCapture.AudioRecorder` so the `RecordingController` can be
/// tested with a fake engine (no real Core Audio, no hardware).
///
/// The protocol re-uses `AudioCapture` types (`CapturePaths`, `CaptureState`)
/// directly -- they are lightweight value types already designed for cross-module use.
public protocol RecorderControlling: Sendable {
    /// Surfaces both TCC permission prompts (mic + system audio) without
    /// running the recording pipeline.
    func requestPermissions(systemProbePath: URL) async -> Bool

    /// Starts two-stream capture writing to the given paths.
    func start(paths: CapturePaths) async throws

    /// Stops capture. Idempotent.
    func stop() async

    /// Returns a stream of periodic `CaptureState` snapshots (~250 ms).
    func stateStream() -> AsyncStream<CaptureState>

    /// Returns `true` if the system audio buffers were all-zero in the first
    /// ~2 s, indicating a probable missing screen-recording permission.
    func probableSystemAudioDenied() async -> Bool
}

// Re-export AudioCapture types so downstream modules (AppCore, UI) can use
// `CapturePaths` and `CaptureState` without importing AudioCapture directly.
// Trade-off: `@_exported` is not ABI-stable and could break if Apple changes
// import semantics. Pragmatic for the MVP; if it becomes fragile, replace with
// public type aliases (e.g. `public typealias CapturePaths = AudioCapture.CapturePaths`).
@_exported import struct AudioCapture.CapturePaths
@_exported import struct AudioCapture.CaptureState
