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

        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        Log.coordinator.event(
            "startRecording mode=\(captureMode.rawValue) target=\(targetProcessID.map { "\($0)" } ?? "nil") " +
                "micAuth=\(authStatus.rawValue)"
        )

        switch authStatus {
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

        let timestamp = RecordingFileManager.generateTimestamp()
        let paths = RecordingFileManager.filePaths(timestamp: timestamp)

        micFileURL = paths.mic
        systemFileURL = paths.system
        Log.coordinator.event("beginCapture mic=\(paths.mic.lastPathComponent) system=\(paths.system.lastPathComponent)")

        // Start the mic FIRST, and only bring up the system tap once the mic has
        // actually delivered its first sample buffer. The mic's AVCaptureSession
        // start is asynchronous; creating the system tap's aggregate device
        // before the mic's input IO is live can starve the mic's cold-start (both
        // tracks then stay empty until some audio plays). Gating the system start
        // on the mic's first sample makes "mic-first" deterministic — and the
        // first sample's host time gives us the recording's t=0 to align the
        // two tracks against (see startSystemCapture).
        let mic = MicCapture(fileURL: paths.mic)
        mic.onUnrecoverableError = { [weak self] error in
            Log.coordinator.err("mic unrecoverable error: \(error.localizedDescription)")
            Task { @MainActor in
                self?.lastError = "Microphone (route change): \(error.localizedDescription)"
            }
        }
        mic.onStarted = { [weak self] micAnchorSeconds in
            Log.coordinator.event("mic onStarted (anchor=\(micAnchorSeconds)s) → bringing up system capture")
            Task { @MainActor in
                self?.startSystemCapture(
                    micAnchorSeconds: micAnchorSeconds,
                    captureMode: captureMode,
                    targetProcessID: targetProcessID
                )
            }
        }
        micCapture = mic

        do {
            try mic.start()
        } catch {
            Log.coordinator.err("mic.start() threw: \(error.localizedDescription)")
            micCapture = nil
            lastError = "Microphone: \(error.localizedDescription)"
            return
        }

        startMediaTime = CACurrentMediaTime()
        startTime = Date()
        isRecording = true
    }

    /// Brings up system-audio capture once the mic is confirmed live (its first
    /// sample arrived). System capture is fatal: if it fails to start we tear the
    /// whole recording down. `micAnchorSeconds` (the mic's first-frame host time)
    /// is forwarded so the system track is padded with leading silence to align
    /// with the mic.
    private func startSystemCapture(
        micAnchorSeconds: Double,
        captureMode: CaptureMode,
        targetProcessID: AudioObjectID?
    ) {
        // Bail if the recording was stopped before the mic warmed up, or if
        // system capture has already started (onStarted fires once, but guard).
        guard isRecording, micCapture != nil, systemCapture == nil,
              let systemURL = systemFileURL else { return }

        let sysCapture = SystemAudioCapture(
            fileURL: systemURL,
            captureMode: captureMode,
            targetProcessID: targetProcessID
        )

        do {
            try sysCapture.start(micAnchorSeconds: micAnchorSeconds)
            systemCapture = sysCapture
            Log.coordinator.event("system capture started")
        } catch {
            Log.coordinator.err("system capture FAILED — tearing down recording: \(error.localizedDescription)")
            micCapture?.stop()
            micCapture = nil
            lastError = "System audio: \(error.localizedDescription)"
            isRecording = false
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        Log.coordinator.event(
            "stopRecording — mic file=\(micFileSize) bytes, system file=\(systemFileSize) bytes"
        )

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
