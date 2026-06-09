import AppKit
import AudioCapture
import AVFoundation
import Foundation
import ManualTestKit
import os
import Transcription

/// Derives runnable versions of the ManualTestKit canonical scripts by mapping
/// over their steps and replacing only the placeholder closures with real
/// AudioRecorder and Transcriber calls.
///
/// All heavyweight objects (AudioRecorder, Transcriber) are created once and
/// shared across steps via captured references.
enum WiredScripts {
    /// Returns wired copies of all canonical scripts, ready for the runner.
    static func all() -> [TestScript] {
        allScripts.map { script in
            switch script.id {
            case "audio_capture":
                wireAudioCapture(script)
            case "transcription":
                wireTranscription(script)
            default:
                script
            }
        }
    }

    // MARK: - Shared state

    /// The recorder for the current recording run. `AudioRecorder` is
    /// single-use (reuse throws `recorderConsumed`), so a fresh one is
    /// created on `ac_start_recording` and discarded on `ac_stop_recording`.
    /// The lock just guards hand-off between the start and stop steps.
    private static let activeRecorder = OSAllocatedUnfairLock<AudioRecorder?>(
        initialState: nil
    )

    /// Shared transcriber instance (actor -- hosted via BiscottiTranscriber.xpc).
    private static let transcriber = Transcriber(
        backend: .hosted(serviceName: "net.scosman.biscotti.BiscottiTranscriber")
    )

    /// Directory for captured audio files.
    private static var captureDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("ManualTestApp/Captures", isDirectory: true)
    }

    /// The CapturePaths used for the current recording session.
    private static var currentCapturePaths: CapturePaths {
        let dir = captureDirectory
        return CapturePaths(
            micAAC: dir.appendingPathComponent("mic.aac"),
            systemAAC: dir.appendingPathComponent("system.aac")
        )
    }

    /// Thread-safe holder for the latest transcription result so auto-checks can read it.
    private static let latestTranscriptResult = OSAllocatedUnfairLock<TranscriptResult?>(
        initialState: nil
    )

    // MARK: - Audio Capture wiring

    /// Maps over the canonical audio-capture script, replacing action/autoCheck closures.
    private static func wireAudioCapture(_ script: TestScript) -> TestScript {
        let paths = currentCapturePaths

        let wiredSteps = script.steps.map { step -> TestStep in
            switch step {
            case let .action(id, label, _):
                switch id {
                case "ac_request_permissions":
                    return .action(id: id, label: label) { _ in
                        try FileManager.default.createDirectory(
                            at: captureDirectory,
                            withIntermediateDirectories: true
                        )
                        // Only request permissions — do NOT start the recording
                        // engine. This triggers the mic + system-audio TCC prompts
                        // without touching the mic AVAudioEngine/encoder. TCC grants
                        // are process/bundle-global, so a throwaway recorder is fine.
                        let probe = captureDirectory.appendingPathComponent("permission_probe.aac")
                        await AudioRecorder.live().requestPermissions(systemProbePath: probe)
                    }
                case "ac_start_recording":
                    return .action(id: id, label: label) { _ in
                        try FileManager.default.createDirectory(
                            at: captureDirectory,
                            withIntermediateDirectories: true
                        )
                        // Single-use: a fresh recorder per run, handed to the stop step.
                        let recorder = AudioRecorder.live()
                        activeRecorder.withLock { $0 = recorder }
                        do {
                            try await recorder.start(paths: paths)
                        } catch {
                            activeRecorder.withLock { $0 = nil }
                            throw error
                        }
                    }
                case "ac_stop_recording":
                    return .action(id: id, label: label) { _ in
                        let recorder = activeRecorder.withLock { current -> AudioRecorder? in
                            defer { current = nil }
                            return current
                        }
                        await recorder?.stop()
                        // Reveal both recordings in Finder so the human can play
                        // them for the playback questions that follow — there is
                        // otherwise no UI to open the captures folder.
                        await MainActor.run {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [paths.micAAC, paths.systemAAC]
                            )
                        }
                    }
                default:
                    return step
                }

            case let .autoCheck(id, label, _):
                switch id {
                case "ac_files_exist":
                    return .autoCheck(id: id, label: label) {
                        AutoChecks.checkAACFilesExist(
                            micURL: paths.micAAC,
                            systemURL: paths.systemAAC
                        )
                    }
                default:
                    return step
                }

            case .instruction, .humanQuestion:
                return step
            }
        }

        return TestScript(id: script.id, title: script.title, steps: wiredSteps)
    }

    // MARK: - Transcription wiring

    /// Maps over the canonical transcription script, replacing action/autoCheck closures.
    private static func wireTranscription(_ script: TestScript) -> TestScript {
        let paths = currentCapturePaths

        let wiredSteps = script.steps.map { step -> TestStep in
            switch step {
            case let .action(id, label, _):
                switch id {
                case "tx_clear_cache":
                    return .action(id: id, label: label) { _ in
                        try await transcriber.clearCache()
                    }
                case "tx_model_download":
                    return .action(id: id, label: label) { status in
                        try await transcriber.ensureModelsDownloaded(status: status)
                    }
                case "tx_transcribe":
                    return .action(id: id, label: label) { _ in
                        let result = try await transcriber.processAudio(
                            mic: paths.micAAC,
                            system: paths.systemAAC
                        )
                        latestTranscriptResult.withLock { $0 = result }
                    }
                default:
                    return step
                }

            case let .autoCheck(id, label, _):
                switch id {
                case "tx_speakers":
                    return .autoCheck(id: id, label: label) {
                        guard let result = latestTranscriptResult.withLock({ $0 }) else {
                            return CheckOutcome(
                                passed: false,
                                detail: "No transcription result — run transcribe first"
                            )
                        }
                        let passed = result.speakerCount >= 2
                        return CheckOutcome(
                            passed: passed,
                            detail: "Speaker count: \(result.speakerCount)"
                        )
                    }
                case "tx_no_hallucination":
                    return .autoCheck(id: id, label: label) {
                        guard let result = latestTranscriptResult.withLock({ $0 }) else {
                            return CheckOutcome(
                                passed: false,
                                detail: "No transcription result — run transcribe first"
                            )
                        }
                        let endTimes = result.segments.map(\.endTime)
                        // Compute real audio duration from the mic file using AVAudioFile.
                        // Note: ADTS AAC has no header duration table, so CoreAudio may
                        // return zero/bogus length without throwing. Residual accuracy of
                        // ADTS duration is validated on real hardware in Phase 4.5.
                        let audioDuration: Double
                        do {
                            let audioFile = try AVAudioFile(
                                forReading: paths.micAAC
                            )
                            let frames = Double(audioFile.length)
                            let sampleRate = audioFile.processingFormat.sampleRate
                            audioDuration = sampleRate > 0 ? frames / sampleRate : 0
                        } catch {
                            return CheckOutcome(
                                passed: false,
                                detail: "Cannot read audio duration: \(error.localizedDescription)"
                            )
                        }
                        guard audioDuration > 0 else {
                            return CheckOutcome(
                                passed: false,
                                detail: "Could not determine audio duration (got \(audioDuration)s)"
                            )
                        }
                        return AutoChecks.checkNoSegmentPastDuration(
                            segmentEndTimes: endTimes,
                            audioDuration: audioDuration
                        )
                    }
                default:
                    return step
                }

            case .instruction, .humanQuestion:
                return step
            }
        }

        return TestScript(id: script.id, title: script.title, steps: wiredSteps)
    }
}
