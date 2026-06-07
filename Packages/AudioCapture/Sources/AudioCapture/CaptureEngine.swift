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
