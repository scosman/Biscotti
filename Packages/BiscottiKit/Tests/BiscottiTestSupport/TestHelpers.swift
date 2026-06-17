import AppCore
import AudioCapture
import CoreAudio
import Foundation

/// Polls a condition until true, up to 2 seconds.
///
/// Shared across test targets to avoid duplication.
public func pollUntil(
    _ condition: @MainActor () -> Bool
) async throws {
    for _ in 0 ..< 40 {
        try await Task.sleep(for: .milliseconds(50))
        if await condition() { return }
    }
}

/// Creates an `AudioProcess` test stub for pipeline tests.
///
/// Shared across test targets to avoid duplication.
public func makeAudioProcess(
    bundleID: String,
    input: Bool,
    output: Bool,
    pid: pid_t = 1
) -> AudioProcess {
    AudioProcess(
        id: AudioObjectID(pid),
        bundleID: bundleID,
        pid: pid,
        isRunningInput: input,
        isRunningOutput: output
    )
}

// MARK: - RecordingStartupState test convenience

public extension RecordingStartupState {
    /// Whether this state is a `.failed` case. Convenience for test assertions.
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
