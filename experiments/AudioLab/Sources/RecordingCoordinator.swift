import AppKit
import AVFoundation
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

    /// Drives the microphone-permission alert in RecordView. We refuse to start a
    /// recording when the mic is denied/restricted rather than capturing a silent
    /// file with no feedback (Phase 9 Test 4: denial is otherwise a silent failure
    /// with no usable OSStatus).
    var permissionAlertShown = false
    private(set) var permissionAlertMessage = ""
    private(set) var permissionAlertOffersSettings = false

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

    /// Public entry point: preflight the microphone permission, then capture.
    /// We never start a capture we know will be silent — instead we tell the user
    /// exactly what to fix (and offer to open System Settings when appropriate).
    func startRecording(captureMode: CaptureMode, targetProcessID: AudioObjectID?) {
        guard !isRecording else { return }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginCapture(captureMode: captureMode, targetProcessID: targetProcessID)

        case .notDetermined:
            // First-run: let the OS prompt, then start only if the user grants.
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.beginCapture(captureMode: captureMode, targetProcessID: targetProcessID)
                    } else {
                        self.presentPermissionAlert(
                            "AudioLab needs microphone access to record. You just declined the prompt — enable it in System Settings to record your voice.",
                            offersSettings: true
                        )
                    }
                }
            }

        case .denied:
            presentPermissionAlert(
                "Microphone access for AudioLab is turned off. Without it the mic track records silence. Enable AudioLab under Privacy & Security → Microphone, then try again.",
                offersSettings: true
            )

        case .restricted:
            // Blocked by policy (MDM / parental controls): can't even prompt.
            presentPermissionAlert(
                "Microphone access is blocked by a system policy (e.g. MDM or parental controls) and can't be enabled here.",
                offersSettings: false
            )

        @unknown default:
            presentPermissionAlert(
                "Microphone access is unavailable. Check Privacy & Security → Microphone in System Settings.",
                offersSettings: true
            )
        }
    }

    private func presentPermissionAlert(_ message: String, offersSettings: Bool) {
        permissionAlertMessage = message
        permissionAlertOffersSettings = offersSettings
        permissionAlertShown = true
    }

    /// Opens System Settings directly at Privacy & Security → Microphone.
    func openMicrophoneSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    private func beginCapture(captureMode: CaptureMode, targetProcessID: AudioObjectID?) {
        guard !isRecording else { return }
        lastError = nil

        // TEMP: isolate mic from system-audio tap — set false to re-enable system capture
        let micOnlyDiagnostic = true

        let timestamp = RecordingFileManager.generateTimestamp()
        let paths = RecordingFileManager.filePaths(timestamp: timestamp)

        micFileURL = paths.mic
        systemFileURL = paths.system

        if !micOnlyDiagnostic {
            let sysCapture = SystemAudioCapture(
                fileURL: paths.system,
                captureMode: captureMode,
                targetProcessID: targetProcessID
            )
            systemCapture = sysCapture

            do {
                try sysCapture.start()
            } catch {
                lastError = "System audio: \(error.localizedDescription)"
                return
            }
        }

        let mic = MicCapture(fileURL: paths.mic)
        mic.onUnrecoverableError = { [weak self] error in
            Task { @MainActor in
                self?.lastError = "Microphone (route change): \(error.localizedDescription)"
            }
        }
        micCapture = mic

        do {
            try mic.start()
        } catch {
            systemCapture?.stop()
            lastError = "Microphone: \(error.localizedDescription)"
            return
        }

        startMediaTime = CACurrentMediaTime()
        startTime = Date()
        isRecording = true
    }

    func stopRecording() {
        guard isRecording else { return }

        let sysCapture = systemCapture
        systemCapture?.stop()
        micCapture?.stop()

        // Surface any write errors that occurred during recording.
        if let writeErr = sysCapture?.writeError {
            lastError = "System audio write error during recording (OSStatus \(writeErr))"
        }

        systemCapture = nil
        micCapture = nil
        isRecording = false
    }
}
