import Foundation
@testable import AudioCapture

/// Helpers for building an `AudioRecorder` with test fakes.
enum TestRecorderFactory {
    struct Components {
        let recorder: AudioRecorder
        let systemEngine: FakeCaptureEngine
        let micEngine: FakeCaptureEngine
        let deviceChangeProvider: FakeDeviceChangeProvider
        let permissionChecker: FakeSystemPermissionChecker
        let paths: CapturePaths
        let tempDir: URL
    }

    /// Creates an `AudioRecorder` backed by fakes, with temp-dir paths.
    static func make(probableDenied: Bool = false) throws -> Components {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioRecorderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let paths = CapturePaths(
            micCAF: dir.appendingPathComponent("mic.caf"),
            systemCAF: dir.appendingPathComponent("system.caf"),
            micOutput: dir.appendingPathComponent("mic.m4a"),
            systemOutput: dir.appendingPathComponent("system.m4a")
        )

        let systemEngine = FakeCaptureEngine()
        let micEngine = FakeCaptureEngine()
        let deviceChangeProvider = FakeDeviceChangeProvider()
        let permissionChecker = FakeSystemPermissionChecker(probableDenied: probableDenied)

        let recorder = AudioRecorder(
            systemEngine: systemEngine,
            micEngine: micEngine,
            deviceChangeProvider: deviceChangeProvider,
            permissionChecker: permissionChecker
        )

        return Components(
            recorder: recorder,
            systemEngine: systemEngine,
            micEngine: micEngine,
            deviceChangeProvider: deviceChangeProvider,
            permissionChecker: permissionChecker,
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
