import CoreAudio
import Foundation
import Observation
import QuartzCore

@Observable
@MainActor
final class RecordingCoordinator {
    private(set) var isRecording = false
    private(set) var startTime: Date?
    private(set) var startMediaTime: CFTimeInterval = 0
    private(set) var micFileURL: URL?
    private(set) var systemFileURL: URL?
    private(set) var lastError: String?

    /// Thread-safety: systemCapture and micCapture are created and torn down on
    /// the main thread. Their internal audio callbacks run on dedicated audio/writer
    /// threads and use their own synchronization (ring buffer, os_unfair_lock).
    private var systemCapture: SystemAudioCapture?
    private var micCapture: MicCapture?

    var elapsedTime: TimeInterval {
        guard let start = startTime, isRecording else { return 0 }
        return Date().timeIntervalSince(start)
    }

    var micFileSize: Int64 {
        guard let url = micFileURL else { return 0 }
        return RecordingFileManager.fileSize(at: url)
    }

    var systemFileSize: Int64 {
        guard let url = systemFileURL else { return 0 }
        return RecordingFileManager.fileSize(at: url)
    }

    func startRecording(captureMode: CaptureMode, targetProcessID: AudioObjectID?) {
        guard !isRecording else { return }
        lastError = nil

        let timestamp = RecordingFileManager.generateTimestamp()
        let paths = RecordingFileManager.filePaths(timestamp: timestamp)

        micFileURL = paths.mic
        systemFileURL = paths.system

        let sysCapture = SystemAudioCapture(
            fileURL: paths.system,
            captureMode: captureMode,
            targetProcessID: targetProcessID
        )
        systemCapture = sysCapture

        let mic = MicCapture(fileURL: paths.mic)
        micCapture = mic

        do {
            try sysCapture.start()
        } catch {
            lastError = "System audio: \(error.localizedDescription)"
            return
        }

        do {
            try mic.start()
        } catch {
            sysCapture.stop()
            lastError = "Microphone: \(error.localizedDescription)"
            return
        }

        startMediaTime = CACurrentMediaTime()
        startTime = Date()
        isRecording = true
    }

    func stopRecording() {
        guard isRecording else { return }

        systemCapture?.stop()
        micCapture?.stop()

        systemCapture = nil
        micCapture = nil
        isRecording = false
    }
}
