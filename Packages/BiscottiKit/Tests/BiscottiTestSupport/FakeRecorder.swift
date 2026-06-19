import AudioCapture
import Foundation
import Recording

/// A configurable fake `RecorderControlling` for tests.
///
/// Uses a reference-type backing store so mutations are visible through
/// protocol existentials. The backing store is `@unchecked Sendable` --
/// all access is confined to `@MainActor` test functions in practice.
public struct FakeRecorder: RecorderControlling, @unchecked Sendable {
    public final class Backing: @unchecked Sendable {
        public var startCalled = false
        public var stopCalled = false
        public var requestPermissionsCalled = false
        public var startError: (any Error)?
        public var probableDenied: Bool
        public var stateValues: [CaptureState]
        /// Canned result for `observedSystemAudio()`.
        public var observedSystemAudio: Bool
        /// Canned result for `probeSystemAudioWithTone(timeout:)`.
        public var probeResult: Bool
        public var probeSystemAudioWithToneCalled = false

        public init(
            startError: (any Error)? = nil,
            probableDenied: Bool = false,
            stateValues: [CaptureState] = [],
            observedSystemAudio: Bool = false,
            probeResult: Bool = false
        ) {
            self.startError = startError
            self.probableDenied = probableDenied
            self.stateValues = stateValues
            self.observedSystemAudio = observedSystemAudio
            self.probeResult = probeResult
        }
    }

    public let backing: Backing

    public init(
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

    public func requestPermissions(systemProbePath _: URL) async -> Bool {
        backing.requestPermissionsCalled = true
        return true
    }

    public func start(paths _: CapturePaths) async throws {
        backing.startCalled = true
        if let error = backing.startError {
            throw error
        }
    }

    public func stop() async {
        backing.stopCalled = true
    }

    public func stateStream() -> AsyncStream<CaptureState> {
        let values = backing.stateValues
        return AsyncStream { continuation in
            for value in values {
                continuation.yield(value)
            }
            continuation.finish()
        }
    }

    public func probableSystemAudioDenied() async -> Bool {
        backing.probableDenied
    }

    public func observedSystemAudio() async -> Bool {
        backing.observedSystemAudio
    }

    public func probeSystemAudioWithTone(timeout _: Duration) async -> Bool {
        backing.probeSystemAudioWithToneCalled = true
        return backing.probeResult
    }
}
