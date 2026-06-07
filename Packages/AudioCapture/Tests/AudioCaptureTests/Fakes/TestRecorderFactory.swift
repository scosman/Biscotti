import AVFoundation
import Foundation
@testable import AudioCapture

/// Fake mic permission checker for tests.
final class FakeMicPermissionChecker: MicPermissionChecker, @unchecked Sendable {
    private var _status: AVAuthorizationStatus
    var requestAccessResult: Bool

    init(status: AVAuthorizationStatus = .authorized, requestAccessResult: Bool = true) {
        _status = status
        self.requestAccessResult = requestAccessResult
    }

    func authorizationStatus() -> AVAuthorizationStatus {
        _status
    }

    func requestAccess() async -> Bool {
        requestAccessResult
    }

    func setStatus(_ status: AVAuthorizationStatus) {
        _status = status
    }
}

/// Helpers for building an `AudioRecorder` with test fakes.
enum TestRecorderFactory {
    struct Components {
        let recorder: AudioRecorder
        let systemEngine: FakeCaptureEngine
        let micEngine: FakeCaptureEngine
        let deviceChangeProvider: FakeDeviceChangeProvider
        let permissionChecker: FakeSystemPermissionChecker
        let micPermissionChecker: FakeMicPermissionChecker
        let paths: CapturePaths
        let tempDir: URL
    }

    /// Creates an `AudioRecorder` backed by fakes, with temp-dir paths.
    static func make(
        probableDenied: Bool = false,
        micAuthStatus: AVAuthorizationStatus = .authorized,
        requestAccessResult: Bool = true
    ) throws -> Components {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioRecorderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let paths = CapturePaths(
            micAAC: dir.appendingPathComponent("mic.aac"),
            systemAAC: dir.appendingPathComponent("system.aac")
        )

        let systemEngine = FakeCaptureEngine()
        let micEngine = FakeCaptureEngine()
        let deviceChangeProvider = FakeDeviceChangeProvider()
        let permissionChecker = FakeSystemPermissionChecker(probableDenied: probableDenied)
        let micPermChecker = FakeMicPermissionChecker(status: micAuthStatus, requestAccessResult: requestAccessResult)

        let recorder = AudioRecorder(
            systemEngine: systemEngine,
            micEngine: micEngine,
            deviceChangeProvider: deviceChangeProvider,
            permissionChecker: permissionChecker,
            micPermissionChecker: micPermChecker
        )

        return Components(
            recorder: recorder,
            systemEngine: systemEngine,
            micEngine: micEngine,
            deviceChangeProvider: deviceChangeProvider,
            permissionChecker: permissionChecker,
            micPermissionChecker: micPermChecker,
            paths: paths,
            tempDir: dir
        )
    }

    /// Cleans up the temp directory created by `make()`.
    static func cleanup(_ components: Components) {
        components.deviceChangeProvider.finish()
        try? FileManager.default.removeItem(at: components.tempDir)
    }
}
