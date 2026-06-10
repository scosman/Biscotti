import AVFoundation
import Foundation

/// Seam for a single audio capture stream (mic or system).
///
/// Real implementations use Core Audio / AVAudioEngine and are thin
/// wrappers tested only by the Manual Test App. Tests inject fakes
/// to exercise the `AudioRecorder` orchestration logic.
public protocol CaptureEngine: Sendable {
    /// Begins writing PCM audio to the file at `url`.
    /// Creates (or erases) the file. This is the only method that may erase data.
    func start(writingTo url: URL) async throws

    /// Stops capture and finalizes the file. Idempotent.
    func stop() async

    /// Reconnects hardware (tap, aggregate device, engine) without reopening
    /// the audio file, so already-captured audio is preserved.
    ///
    /// Called on route-change events while recording is active. The file
    /// writer continues appending to the same file. Only the hardware
    /// pipeline is torn down and rebuilt.
    ///
    /// Default implementation falls back to stop + start (file-erasing)
    /// for engines that don't support reconnect, but production engines
    /// must override to preserve audio.
    func reconnect() async throws

    /// Registers a callback fired exactly once when the engine delivers its
    /// first audio buffer. The argument is the host-clock anchor (seconds,
    /// derived from `AudioConvertHostTimeToNanos`). Used by the mic engine
    /// to signal the recording's t=0 so the system track can be aligned.
    ///
    /// Called by `AudioRecorder` before `start()`. Engines that don't produce
    /// an anchor (system, fakes) can ignore it — the default is a no-op.
    /// Pass `nil` to clear a previously registered callback.
    func setOnFirstBuffer(_ callback: (@Sendable (Double) -> Void)?)

    /// Sets the mic's first-buffer host-clock anchor (seconds) so the
    /// system engine can prepend leading silence to align the two tracks.
    /// No-op for engines that don't need alignment (mic, fakes).
    func setMicAnchor(_ seconds: Double)

    /// Non-nil if `ExtAudioFileWrite` failed during recording. Read after
    /// `stop()` to surface write errors. Nil for engines without a write
    /// path (mic engine, fakes).
    var writeError: OSStatus? { get }
}

public extension CaptureEngine {
    func setOnFirstBuffer(_: (@Sendable (Double) -> Void)?) {}

    func setMicAnchor(_: Double) {}

    var writeError: OSStatus? {
        nil
    }
}

/// A device-change event relevant to capture continuity.
public enum DeviceChangeEvent: Sendable, Equatable {
    /// The default output device changed (e.g. speaker -> AirPods).
    /// System audio tap + aggregate device must be rebuilt.
    case outputChanged
    /// The default input device changed (e.g. built-in mic -> AirPods mic).
    /// AVAudioEngine must be restarted.
    case inputChanged
}

/// Seam for device-change observation.
///
/// Real: Core Audio property listeners + AVAudioEngineConfigurationChange.
/// Tests: inject a `Continuation` to push synthetic events.
public protocol DeviceChangeProvider: Sendable {
    /// Returns an async stream of device-change events.
    func deviceChanges() -> AsyncStream<DeviceChangeEvent>
}

/// Seam for detecting probable system audio permission denial.
///
/// Real: monitors the first ~2 s of system audio buffers for all-zeros.
/// Tests: return a canned Bool.
public protocol SystemPermissionChecker: Sendable {
    func probableDenied() async -> Bool
}

/// Seam for mic permission preflight.
///
/// Real: wraps `AVCaptureDevice.authorizationStatus(for: .audio)`.
/// Tests: inject a canned `AVAuthorizationStatus`.
public protocol MicPermissionChecker: Sendable {
    func authorizationStatus() -> AVAuthorizationStatus

    /// Requests mic access from the user. Returns `true` if granted.
    ///
    /// Called when `authorizationStatus()` returns `.notDetermined`.
    func requestAccess() async -> Bool
}

/// Seam for audio process activity observation.
///
/// Real: Core Audio property listeners (`kAudioHardwarePropertyProcessObjectList`
/// + per-process `kAudioProcessPropertyIsRunning`).
/// Tests: inject synthetic process lists and push change notifications.
public protocol ProcessActivitySource: Sendable {
    /// Returns the current snapshot of audio processes.
    func currentProcesses() -> [AudioProcess]

    /// Returns a stream that fires whenever the process list changes or
    /// any tracked process's running state toggles. The consumer should
    /// call `currentProcesses()` to get the updated snapshot.
    func processChanges() -> AsyncStream<Void>
}
