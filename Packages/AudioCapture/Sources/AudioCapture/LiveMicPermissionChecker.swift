import AVFoundation

/// Thin production wrapper around `AVCaptureDevice` mic permission APIs.
final class LiveMicPermissionChecker: MicPermissionChecker {
    func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
