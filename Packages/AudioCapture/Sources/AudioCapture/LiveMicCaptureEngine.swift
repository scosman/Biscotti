import AudioToolbox
@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os
import Synchronization

private let logger = Logger(subsystem: "net.scosman.biscotti.audiocapture", category: "LiveMicCapture")

/// Passive microphone capture through an input-only `AVAudioEngine` tap.
///
/// The meeting app owns voice processing. Enabling VPIO here can suppress
/// its microphone, so recording must not create voice-processing output,
/// duck other audio, or change a shared device's sample rate.
/// Thin hardware adapter -- orchestration lives in `AudioRecorder`.
final class LiveMicCaptureEngine: CaptureEngine, @unchecked Sendable {
    private let encoder: EncoderSettings

    /// Owned by engineQueue; each start gets a separate file and callback lifetime.
    private var session: MicCaptureSession?

    /// Atomic capturing flag -- safe from async contexts.
    private let capturingFlag = Atomic<Bool>(false)

    /// `.userInitiated` matches the QoS of the `AudioRecorder` actor tasks that
    /// `await` start()/stop()/reconnect(): without an explicit QoS the queue runs
    /// at Default, so a user-initiated task awaiting it is a priority inversion
    /// (the runtime flags "User-initiated … waiting on a … Default QoS thread").
    private let engineQueue = DispatchQueue(
        label: "net.scosman.biscotti.mic.engine", qos: .userInitiated
    )
    private var isTearingDown = false
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?

    /// First mic write error from the most recent session. Cleared at
    /// the start of each recording; set during `closeSession()` after the
    /// writer thread drains. Thread-safe via `Mutex`.
    private let _micWriteError = Mutex<OSStatus?>(nil)

    /// Non-nil if the mic session's ExtAudioFileWrite failed during
    /// recording. Read after `stop()` to surface write errors.
    var writeError: OSStatus? {
        _micWriteError.withLock { $0 }
    }

    var onUnrecoverableError: (@Sendable (Error) -> Void)?

    /// Registration is copied into each session before capture starts. Audio
    /// callbacks never read this mutable slot or observe a later attempt's callback.
    private let firstBufferCallback = Mutex<(@Sendable (Double) -> Void)?>(nil)

    /// Registers the first-buffer callback for the next capture attempt.
    func setOnFirstBuffer(_ callback: (@Sendable (Double) -> Void)?) {
        firstBufferCallback.withLock { $0 = callback }
    }

    /// Configures the file encoding used by each independent recording attempt.
    init(encoder: EncoderSettings = .voice) {
        self.encoder = encoder
    }

    // MARK: - CaptureEngine conformance

    /// Opens a fresh recording session and starts microphone input on the lifecycle queue.
    func start(writingTo url: URL) async throws {
        guard !capturingFlag.load(ordering: .acquiring) else { return }
        let callback = firstBufferCallback.withLock { $0 }
        _micWriteError.withLock { $0 = nil }
        capturingFlag.store(true, ordering: .releasing)

        // Keep blocking hardware setup on engineQueue. Install the observer
        // after initial setup so an unfinished graph cannot queue recovery.
        // Later notifications are handled against the current engine state.
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                engineQueue.async { [self] in
                    isTearingDown = false
                    do {
                        session = try MicCaptureSession(url: url, encoder: encoder, onFirstBuffer: callback)
                        try buildAndStartEngineOrThrow()
                        installConfigChangeObserver()
                        cont.resume()
                    } catch {
                        teardownEngine()
                        closeSession()
                        capturingFlag.store(false, ordering: .releasing)
                        cont.resume(throwing: error)
                    }
                }
            }
        } catch {
            throw CaptureError.micEngineFailed(
                error.localizedDescription
            )
        }
    }

    /// Invalidates tap callbacks, stops microphone input and finalizes the session file.
    func stop() async {
        guard capturingFlag.exchange(false, ordering: .acquiringAndReleasing) else {
            return
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            engineQueue.async { [self] in
                isTearingDown = true
                removeConfigChangeObserver()
                teardownEngine()
                closeSession()
                cont.resume()
            }
        }
    }

    /// Rebuilds hardware while retaining the session file and its first anchor.
    func reconnect() async throws {
        guard capturingFlag.load(ordering: .acquiring) else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            engineQueue.async { [self] in
                guard !isTearingDown else {
                    cont.resume()
                    return
                }
                if let inID = CoreAudioHelpers.defaultInputDeviceID() {
                    let name = CoreAudioHelpers.deviceName(for: inID) ?? "unknown"
                    logger.info("Mic reconnect: following default input \"\(name)\" id=\(inID)")
                }
                teardownEngine()
                do {
                    try buildAndStartEngineOrThrow()
                    cont.resume()
                } catch {
                    logger.error("Mic reconnect failed: \(error.localizedDescription)")
                    removeConfigChangeObserver()
                    teardownEngine()
                    closeSession()
                    capturingFlag.store(false, ordering: .releasing)
                    cont.resume(throwing: CaptureError.micEngineFailed(
                        error.localizedDescription
                    ))
                }
            }
        }
    }

    /// Releases the observer and recording resources when no capture task owns us.
    deinit {
        // Remove the observer first so no config-change fires during teardown.
        removeConfigChangeObserver()
        teardownEngine()
        closeSession()
    }

    // MARK: - Engine lifecycle (engineQueue)

    /// Throwing core of the engine build (initial start + route-change).
    private func buildAndStartEngineOrThrow() throws {
        guard capturingFlag.load(ordering: .acquiring) else { return }

        let newEngine = AVAudioEngine()
        engine = newEngine // store early so teardownEngine() works on failure
        try installCaptureGraphAndStart(newEngine)
    }

    /// Re-query the hardware format for both initial setup and startup recovery.
    /// Recording consumes the input's native format; the writer resamples it
    /// without reconfiguring the microphone or output device.
    private func installCaptureGraphAndStart(_ engine: AVAudioEngine) throws {
        let input = engine.inputNode
        let tapFormat = input.outputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
            throw CaptureError.micEngineFailed("The microphone has no usable audio format.")
        }
        let inputID = CoreAudioHelpers.defaultInputDeviceID() ?? 0
        let outputID = CoreAudioHelpers.defaultOutputDeviceID() ?? 0
        let inputRate = CoreAudioHelpers.nominalSampleRate(for: inputID) ?? 0
        let outputRate = CoreAudioHelpers.nominalSampleRate(for: outputID) ?? 0
        let inputName = CoreAudioHelpers.deviceName(for: inputID) ?? "unknown"
        let outputName = CoreAudioHelpers.deviceName(for: outputID) ?? "unknown"
        logger.notice("Mic setup: passive=true voiceProcessing=\(input.isVoiceProcessingEnabled, privacy: .public); input=\(inputName) id=\(inputID, privacy: .public) rate=\(inputRate, privacy: .public); output=\(outputName) id=\(outputID, privacy: .public) rate=\(outputRate, privacy: .public); tap rate=\(tapFormat.sampleRate, privacy: .public) channels=\(tapFormat.channelCount, privacy: .public)")

        guard let session else {
            throw CaptureError.micEngineFailed("No microphone recording session is open.")
        }
        input.installTap(
            onBus: 0, bufferSize: 1024, format: tapFormat,
            block: session.makeTapHandler()
        )

        engine.prepare()
        try engine.start()
    }

    /// Restarts a settling graph in place, or rebuilds after established audio delivery.
    private func recoverEngineAfterConfigurationChange(_ current: AVAudioEngine, hasDeliveredBuffer: Bool) {
        do {
            if hasDeliveredBuffer {
                logger.notice("Config-change honoured — rebuilding mic engine after audio delivery")
                teardownEngine()
                try buildAndStartEngineOrThrow()
            } else {
                // Refresh the stopped graph in place while the input route settles.
                // Keep the recording session and its first-buffer anchor intact.
                logger.notice("Config-change honoured — restarting existing mic engine during startup")
                session?.invalidateTap()
                current.inputNode.removeTap(onBus: 0)
                try installCaptureGraphAndStart(current)
                logger.notice("Mic startup restart completed: running=\(current.isRunning, privacy: .public)")
            }
        } catch {
            logger.error("Mic configuration recovery failed: \(error.localizedDescription, privacy: .public)")
            // stop() becomes a no-op once capturingFlag is cleared. Remove the
            // observer here so a later startup retry cannot leave it registered.
            removeConfigChangeObserver()
            teardownEngine()
            closeSession()
            capturingFlag.store(false, ordering: .releasing)
            // Keep the error handler off the serial engine lifecycle queue.
            let handler = onUnrecoverableError
            DispatchQueue.global().async { handler?(error) }
        }
    }

    /// Invalidates queued callbacks before stopping the input-only graph.
    private func teardownEngine() {
        session?.invalidateTap()
        guard let eng = engine else { return }
        eng.inputNode.removeTap(onBus: 0)
        if eng.isRunning { eng.stop() }
        engine = nil
        logger.notice("Mic input stopped")
    }

    // MARK: - Config-change observer

    /// Installs the config-change observer. Must run on `engineQueue`
    /// (same as `removeConfigChangeObserver`) so `configObserver` is
    /// accessed from a single serial context.
    private func installConfigChangeObserver() {
        // Follow rebuilt engines, but ignore queued notifications from an old
        // graph or another AVAudioEngine in this process.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] notification in
            guard let source = notification.object as? AVAudioEngine else { return }
            self?.handleConfigurationChange(engineID: ObjectIdentifier(source))
        }
    }

    /// Removes the config-change observer. Must run on `engineQueue`
    /// (same as `installConfigChangeObserver`) so `configObserver` is
    /// accessed from a single serial context. Exception: `deinit`, where
    /// no concurrent access is possible.
    private func removeConfigChangeObserver() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
    }

    /// A configuration notification may arrive before the first input buffer.
    /// Ignore it only while the current graph is still running; otherwise
    /// restart it using the input route's newly queried format.
    /// AudioRecorder independently bounds the wait for the first written buffer.
    private func handleConfigurationChange(engineID: ObjectIdentifier) {
        engineQueue.async { [weak self] in
            guard let self, !isTearingDown, capturingFlag.load(ordering: .acquiring),
                  let engine, ObjectIdentifier(engine) == engineID else { return }

            let settled = session?.hasDeliveredBuffer ?? false
            let running = engine.isRunning
            logger.notice("Mic config change: running=\(running, privacy: .public), bufferDelivered=\(settled, privacy: .public)")

            if !settled, running {
                // The input graph is still settling and has not stopped.
                logger.info("Config-change absorbed during startup settle (no buffer yet)")
                return
            }

            recoverEngineAfterConfigurationChange(engine, hasDeliveredBuffer: settled)
        }
    }

    /// Finalizes the current attempt after its hardware has been stopped.
    /// Transfers any write error from the session before releasing it.
    private func closeSession() {
        session?.close()
        if let sessionError = session?.writeError {
            _micWriteError.withLock { $0 = $0 ?? sessionError }
        }
        session = nil
    }
}

// MARK: - Buffer helpers (pure, testable)

/// Pure audio-buffer operations used by the microphone writer. Extracted from the
/// engine class so they can be unit-tested without hardware.
enum MicBufferHelper {
    /// Resamples a PCM buffer to `targetFormat` via the supplied converter.
    static func convert(
        _ source: AVAudioPCMBuffer,
        to targetFormat: AVAudioFormat,
        using converter: AVAudioConverter
    ) -> AVAudioPCMBuffer? {
        let frameCapacity = AVAudioFrameCount(
            Double(source.frameLength) * targetFormat.sampleRate / source.format.sampleRate
        )
        guard frameCapacity > 0,
              let output = AVAudioPCMBuffer(
                  pcmFormat: targetFormat, frameCapacity: frameCapacity
              )
        else { return nil }

        var error: NSError?
        nonisolated(unsafe) var hasProvidedData = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if hasProvidedData { outStatus.pointee = .noDataNow; return nil }
            hasProvidedData = true
            outStatus.pointee = .haveData
            return source
        }
        converter.convert(to: output, error: &error, withInputFrom: inputBlock)
        if let error {
            logger.error("AVAudioConverter error: \(error.localizedDescription)")
            return nil
        }
        guard output.frameLength > 0 else { return nil }
        return output
    }

    /// Submits PCM frames to the AAC writer and reports encoder failures.
    @discardableResult
    static func writeBuffer(
        _ buffer: AVAudioPCMBuffer, to file: ExtAudioFileRef
    ) -> OSStatus {
        let status = ExtAudioFileWrite(
            file, buffer.frameLength, buffer.mutableAudioBufferList
        )
        if status != noErr {
            logger.error("ExtAudioFileWrite error: \(status)")
        }
        return status
    }
}
