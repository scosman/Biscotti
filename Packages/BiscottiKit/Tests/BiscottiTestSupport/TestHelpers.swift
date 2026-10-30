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

// MARK: - Audio file fixtures

/// Creates a fresh temporary directory for source audio files. The caller
/// removes it when done.
public func makeTempAudioSourceDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("AudioSrc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Writes a minimal 16-bit mono 8 kHz PCM WAV of silence (0.5 s by default)
/// that AVFoundation can open. Returns its URL.
public func writeSilentWAV(
    named name: String, in dir: URL, frames: Int = 4000
) throws -> URL {
    let sampleRate: UInt32 = 8000
    let dataSize = UInt32(frames * 2)
    var data = Data()
    func append32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    func append16(_ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    append32(36 + dataSize)
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append32(16)
    append16(1) // PCM
    append16(1) // mono
    append32(sampleRate)
    append32(sampleRate * 2)
    append16(2)
    append16(16)
    data.append(contentsOf: Array("data".utf8))
    append32(dataSize)
    data.append(Data(count: Int(dataSize)))
    let url = dir.appendingPathComponent(name)
    try data.write(to: url)
    return url
}

// MARK: - RecordingStartupState test convenience

public extension RecordingStartupState {
    /// Whether this state is a `.failed` case. Convenience for test assertions.
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
