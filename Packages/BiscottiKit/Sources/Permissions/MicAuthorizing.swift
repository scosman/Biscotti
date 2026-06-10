import AVFoundation

/// Seam over the system's microphone authorization API.
///
/// The production implementation (`LiveMicAuthorizer`) calls through to
/// `AVCaptureDevice`; tests inject a fake that returns scripted values.
public protocol MicAuthorizing: Sendable {
    /// Returns the current microphone authorization status.
    func status() -> PermissionState

    /// Triggers the system permission prompt (no-op if already determined).
    /// Returns `true` if access was granted.
    func request() async -> Bool
}

/// Production implementation that delegates to `AVCaptureDevice`.
public struct LiveMicAuthorizer: MicAuthorizing, Sendable {
    public init() {}

    public func status() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            .notDetermined
        case .authorized:
            .authorized
        case .denied, .restricted:
            .denied
        @unknown default:
            .denied
        }
    }

    public func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
