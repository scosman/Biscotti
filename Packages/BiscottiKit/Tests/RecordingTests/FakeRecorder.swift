import AudioCapture
import Foundation
import Recording

/// A configurable fake `RecorderControlling` for tests.
///
/// Uses a reference-type backing store so mutations are visible through
/// protocol existentials. The backing store is `@unchecked Sendable` --
/// all access is confined to `@MainActor` test functions in practice.
struct FakeRecorder: RecorderControlling, @unchecked Sendable {
    final class Backing: @unchecked Sendable {
        var startCalled = false
        var stopCalled = false
        var requestPermissionsCalled = false
        var startError: (any Error)?
        var probableDenied: Bool
        var stateValues: [CaptureState]

        init(
            startError: (any Error)? = nil,
            probableDenied: Bool = false,
            stateValues: [CaptureState] = []
        ) {
            self.startError = startError
            self.probableDenied = probableDenied
            self.stateValues = stateValues
        }
    }

    let backing: Backing

    init(
        startError: (any Error)? = nil,
        probableDenied: Bool = false,
        stateValues: [CaptureState] = []
    ) {
        backing = Backing(
            startError: startError,
            probableDenied: probableDenied,
            stateValues: stateValues
        )
    }

    func requestPermissions(systemProbePath _: URL) async -> Bool {
        backing.requestPermissionsCalled = true
        return true
    }

    func start(paths _: CapturePaths) async throws {
        backing.startCalled = true
        if let error = backing.startError {
            throw error
        }
    }

    func stop() async {
        backing.stopCalled = true
    }

    func stateStream() -> AsyncStream<CaptureState> {
        let values = backing.stateValues
        return AsyncStream { continuation in
            for value in values {
                continuation.yield(value)
            }
            continuation.finish()
        }
    }

    func probableSystemAudioDenied() async -> Bool {
        backing.probableDenied
    }
}
