import AudioToolbox
@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os
import Synchronization

private let logger = Logger(subsystem: "net.scosman.biscotti.audiocapture", category: "LiveMicCapture")

/// Live microphone capture via **VoiceProcessingIO** (`AVAudioEngine`
/// with `inputNode.setVoiceProcessingEnabled(true)`).
///
/// VPIO is the only route to loud, normalised, noise-suppressed mono.
/// Thin hardware adapter -- orchestration lives in `AudioRecorder`.
final class LiveMicCaptureEngine: CaptureEngine, @unchecked Sendable { // swiftlint:disable:this type_body_length
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
    private var silenceNode: AVAudioSourceNode?
    private var configObserver: NSObjectProtocol?
    private var outputRateOverride: (deviceID: AudioObjectID, originalRate: Double)?

    /// Counts capture graphs started on engineQueue: the initial start, every
    /// restart and every rebuild. A reconnect reads it to see whether the
    /// configuration-change path has already restarted the graph.
    private let graphGeneration = Atomic<Int>(0)

    /// Default devices the current engine was built for. Nil when there is no
    /// engine or the devices could not be read. Owned by engineQueue.
    private var engineRoute: MicRoute?

    /// How long a reconnect request waits for a freshly started engine's first
    /// buffer before it treats the request as a route change. On hardware, the
    /// first buffer arrived 0.13–0.37 s after a voice-processing start.
    static let reconnectFirstBufferTimeout: Duration = .seconds(1)

    /// How long a reconnect waits for voice processing to finish following a
    /// device change before it rebuilds the graph itself. On hardware, voice
    /// processing took 0.7–2.2 s to reconfigure after an AirPods change.
    static let voiceProcessingSettleTimeout: Duration = .seconds(3)

    /// How long a restart after audio delivery may run without a buffer
    /// before it is replaced by a full rebuild. An AirPods mic delivered its
    /// first buffer up to 0.9 s after the graph started.
    static let restartFirstBufferTimeout: TimeInterval = 2

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

    /// Opens a fresh recording session and starts VPIO on the lifecycle queue.
    func start(writingTo url: URL) async throws {
        guard !capturingFlag.load(ordering: .acquiring) else { return }
        let callback = firstBufferCallback.withLock { $0 }
        _micWriteError.withLock { $0 = nil }
        capturingFlag.store(true, ordering: .releasing)

        // Run the initial engine build on engineQueue via a continuation so
        // we don't block a cooperative thread. The build (including the ~1 s
        // output-device reclock poll) completes before start() returns, so
        // AudioRecorder can start the system engine against a stable rate.
        // Route-change rebuilds remain fire-and-forget via handleConfigurationChange.
        //
        // Install the observer after initial setup so enabling VPIO does not
        // queue recovery for an unfinished graph. Later settling notifications
        // are handled according to the current engine's running/buffer state.
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
                        restoreOutputRate()
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

    /// Invalidates tap callbacks, tears down VPIO and finalizes the session file.
    func stop() async {
        guard capturingFlag.exchange(false, ordering: .acquiringAndReleasing) else {
            return
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            engineQueue.async { [self] in
                isTearingDown = true
                removeConfigChangeObserver()
                teardownEngine()
                restoreOutputRate()
                closeSession()
                cont.resume()
            }
        }
    }

    /// Follows a default-device change while retaining the session file and its
    /// first anchor.
    ///
    /// Requests can be stale: `AudioRecorder` handles each input change after
    /// the previous reconnect, so a route flap can be over by then. If the
    /// engine runs on the current default devices and delivers audio, it is
    /// kept (see `MicReconnectPolicy`).
    ///
    /// Voice processing follows a default-device change by itself. When it has
    /// finished, AVAudioEngine stops and posts a configuration change, and
    /// `handleConfigurationChange` restarts the graph. Disabling voice
    /// processing while it is still reconfiguring can crash (#124) or deadlock
    /// inside AudioDSP. So a reconnect for a real change waits for that
    /// restart, and rebuilds here only if none comes within
    /// `voiceProcessingSettleTimeout`.
    func reconnect() async throws {
        guard capturingFlag.load(ordering: .acquiring) else { return }
        let generation = graphGeneration.load(ordering: .acquiring)
        let waitStart = Date()
        if await keepsEngineForStaleRequest(since: waitStart) { return }
        await Self.waitForGraphRebuild(
            after: generation,
            timeout: Self.voiceProcessingSettleTimeout,
            currentGeneration: { self.graphGeneration.load(ordering: .acquiring) },
            isCapturing: { self.capturingFlag.load(ordering: .acquiring) }
        )
        let waited = Date().timeIntervalSince(waitStart)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            engineQueue.async { [self] in
                do {
                    try rebuildUnlessRestarted(since: generation, waited: waited)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Returns true, and logs it, when the engine already runs on the current
    /// default devices and delivers audio. A fresh engine gets up to
    /// `reconnectFirstBufferTimeout` for its first buffer.
    private func keepsEngineForStaleRequest(since waitStart: Date) async -> Bool {
        var detail = ""
        let decision = await Self.settleReconnectDecision(
            timeout: Self.reconnectFirstBufferTimeout,
            decision: {
                let state = await self.reconnectState()
                detail = state.detail
                return state.decision
            },
            isCapturing: { self.capturingFlag.load(ordering: .acquiring) }
        )
        guard decision == .keepEngine else { return false }
        let waited = Date().timeIntervalSince(waitStart)
        logger.notice("Mic reconnect: keeping current engine; \(detail, privacy: .public), waited=\(waited, privacy: .public)s")
        return true
    }

    /// Rebuilds the graph for a reconnect unless the configuration-change
    /// path has restarted it since `generation`, or the engine is current by
    /// now. Runs on engineQueue.
    private func rebuildUnlessRestarted(since generation: Int, waited: TimeInterval) throws {
        guard !isTearingDown else { return }
        guard graphGeneration.load(ordering: .acquiring) == generation else {
            logger.notice("Mic reconnect: configuration change already restarted the graph (waited \(waited, privacy: .public)s)")
            return
        }
        let state = reconnectStateOnQueue()
        guard state.decision != .keepEngine else {
            logger.notice("Mic reconnect: keeping current engine; \(state.detail, privacy: .public), waited=\(waited, privacy: .public)s")
            return
        }
        logger.notice("Mic reconnect: no configuration change after \(waited, privacy: .public)s; rebuilding; \(state.detail, privacy: .public)")
        teardownEngine()
        do {
            try buildAndStartEngineOrThrow()
        } catch {
            logger.error("Mic reconnect failed: \(error.localizedDescription)")
            removeConfigChangeObserver()
            teardownEngine()
            restoreOutputRate()
            closeSession()
            capturingFlag.store(false, ordering: .releasing)
            throw CaptureError.micEngineFailed(error.localizedDescription)
        }
    }

    /// Releases the observer and recording resources when no capture task owns us.
    deinit {
        // Remove the observer first so no config-change fires during teardown.
        removeConfigChangeObserver()
        teardownEngine()
        restoreOutputRate()
        closeSession()
    }

    // MARK: - Engine lifecycle (engineQueue)

    /// Throwing core of the engine build (initial start + route-change).
    private func buildAndStartEngineOrThrow() throws {
        guard capturingFlag.load(ordering: .acquiring) else { return }

        ensureOutputRateMatchesInput()

        let newEngine = AVAudioEngine()
        engine = newEngine // store early so teardownEngine() works on failure
        let input = newEngine.inputNode

        try input.setVoiceProcessingEnabled(true)
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(
            enableAdvancedDucking: false, duckingLevel: .min
        )

        try installCaptureGraphAndStart(newEngine)
    }

    /// Re-query the hardware format for initial setup, rebuilds and restarts.
    /// The existing voice-processing unit stays enabled when restarting a stopped
    /// engine, so a restart does not recreate the aggregate device that just settled.
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
        logger.notice("Mic setup: input=\(inputName) id=\(inputID, privacy: .public) rate=\(inputRate, privacy: .public); output=\(outputName) id=\(outputID, privacy: .public) rate=\(outputRate, privacy: .public); tap rate=\(tapFormat.sampleRate, privacy: .public) channels=\(tapFormat.channelCount, privacy: .public)")
        attachSilentOutput(to: engine, inputRate: tapFormat.sampleRate)

        guard let session else {
            throw CaptureError.micEngineFailed("No microphone recording session is open.")
        }
        input.installTap(
            onBus: 0, bufferSize: 1024, format: tapFormat,
            block: session.makeTapHandler()
        )

        engine.prepare()
        try engine.start()
        engineRoute = inputID != 0 && outputID != 0
            ? MicRoute(inputID: inputID, outputID: outputID) : nil
        graphGeneration.wrappingAdd(1, ordering: .releasing)
    }

    /// The reconnect decision for the current engine, with the facts behind it
    /// for the log. Runs on engineQueue.
    private func reconnectStateOnQueue() -> (decision: MicReconnectDecision, detail: String) {
        let builtRoute = engineRoute
        let currentRoute = MicRoute.currentDefault()
        let running = engine?.isRunning ?? false
        let delivered = session?.hasDeliveredBuffer ?? false
        let decision = MicReconnectPolicy.decide(
            builtRoute: builtRoute, currentRoute: currentRoute,
            isRunning: running, hasDeliveredAudio: delivered
        )
        let built = builtRoute.map(String.init(describing:)) ?? "none"
        let current = currentRoute.map(String.init(describing:)) ?? "unknown"
        return (decision, "built for \(built), current \(current), running=\(running), bufferDelivered=\(delivered)")
    }

    /// Reads `reconnectStateOnQueue()` from outside engineQueue.
    private func reconnectState() async -> (decision: MicReconnectDecision, detail: String) {
        await withCheckedContinuation { cont in
            engineQueue.async { [self] in cont.resume(returning: reconnectStateOnQueue()) }
        }
    }

    /// Polls `decision()` while it is `.awaitFirstBuffer`, until `timeout`
    /// passes or capture stops. Returns the last decision.
    static func settleReconnectDecision(
        timeout: Duration,
        pollInterval: Duration = .milliseconds(25),
        decision: () async -> MicReconnectDecision,
        isCapturing: () -> Bool
    ) async -> MicReconnectDecision {
        let deadline = ContinuousClock.now + timeout
        var current = await decision()
        while current == .awaitFirstBuffer, isCapturing(), ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                break // the recorder is stopping
            }
            current = await decision()
        }
        return current
    }

    /// Polls until `currentGeneration()` differs from `generation`, `timeout`
    /// passes, or capture stops. Returns true if a new graph started.
    @discardableResult
    static func waitForGraphRebuild(
        after generation: Int,
        timeout: Duration,
        pollInterval: Duration = .milliseconds(50),
        currentGeneration: () -> Int,
        isCapturing: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while currentGeneration() == generation, isCapturing(), ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                break // the recorder is stopping
            }
        }
        return currentGeneration() != generation
    }

    /// Restarts the existing engine and its voice-processing unit after a
    /// configuration change. After audio delivery, rebuilds only if the
    /// restart fails or the restarted tap stays silent.
    ///
    /// Voice processing follows a default-device change by itself, so when
    /// AVAudioEngine stops after the change, the unit already runs on the new
    /// device. A rebuild would disable it (0.9–2.8 s on hardware, and it can
    /// crash or hang while the unit is still reconfiguring, #124) and create a
    /// new aggregate device (1.3–2.7 s).
    private func recoverEngineAfterConfigurationChange(_ current: AVAudioEngine, hasDeliveredBuffer: Bool) {
        do {
            if hasDeliveredBuffer {
                logger.notice("Config-change honoured — restarting existing mic engine after audio delivery")
                do {
                    try restartExistingEngine(current)
                    logger.notice("Mic restart completed: running=\(current.isRunning, privacy: .public)")
                    scheduleRestartCheck(for: current)
                } catch {
                    logger.notice("Mic restart failed: \(error.localizedDescription, privacy: .public); rebuilding")
                    teardownEngine()
                    try buildAndStartEngineOrThrow()
                }
            } else {
                // Recreating VPIO on every pre-buffer stop repeatedly provokes the
                // same startup configuration change on some Bluetooth/display routes.
                // Keep the stopped engine and VPIO unit; refresh only our tap/output.
                logger.notice("Config-change honoured — restarting existing mic engine during startup")
                try restartExistingEngine(current)
                logger.notice("Mic startup restart completed: running=\(current.isRunning, privacy: .public)")
            }
        } catch {
            failCapture(error)
        }
    }

    /// Keeps the engine and its voice-processing unit; re-queries the format,
    /// then reinstalls the tap and silent output and starts the engine again.
    private func restartExistingEngine(_ current: AVAudioEngine) throws {
        session?.invalidateTap()
        engineRoute = nil
        current.inputNode.removeTap(onBus: 0)
        if current.isRunning { current.stop() }
        if let node = silenceNode { current.detach(node) }
        silenceNode = nil
        try installCaptureGraphAndStart(current)
    }

    /// Rebuilds the graph if a restart after audio delivery has delivered no
    /// buffer within `restartFirstBufferTimeout`. Nothing else will: the
    /// engine stays running, so no further configuration change arrives.
    private func scheduleRestartCheck(for restarted: AVAudioEngine) {
        let generation = graphGeneration.load(ordering: .acquiring)
        let restartedID = ObjectIdentifier(restarted)
        engineQueue.asyncAfter(deadline: .now() + Self.restartFirstBufferTimeout) { [weak self] in
            guard let self, !isTearingDown, capturingFlag.load(ordering: .acquiring),
                  let engine, ObjectIdentifier(engine) == restartedID,
                  graphGeneration.load(ordering: .acquiring) == generation,
                  session?.hasDeliveredBuffer == false else { return }
            logger.notice("Mic restart delivered no audio in \(Self.restartFirstBufferTimeout, privacy: .public)s; rebuilding")
            do {
                teardownEngine()
                try buildAndStartEngineOrThrow()
            } catch {
                failCapture(error)
            }
        }
    }

    /// Ends capture after recovery failed and reports the error.
    private func failCapture(_ error: Error) {
        logger.error("Mic configuration recovery failed: \(error.localizedDescription, privacy: .public)")
        // stop() becomes a no-op once capturingFlag is cleared. Remove the
        // observer here so a later startup retry cannot leave it registered.
        removeConfigChangeObserver()
        teardownEngine()
        restoreOutputRate()
        closeSession()
        capturingFlag.store(false, ordering: .releasing)
        // Keep the error handler off the serial engine lifecycle queue.
        let handler = onUnrecoverableError
        DispatchQueue.global().async { handler?(error) }
    }

    /// Reconciles duplex device rates before creating the voice-processing graph.
    private func ensureOutputRateMatchesInput() {
        guard let inID = CoreAudioHelpers.defaultInputDeviceID(),
              let inRate = CoreAudioHelpers.nominalSampleRate(for: inID),
              let outID = CoreAudioHelpers.defaultOutputDeviceID(),
              let outRate = CoreAudioHelpers.nominalSampleRate(for: outID)
        else { return }
        guard abs(inRate - outRate) > 1 else { return }
        if outputRateOverride == nil {
            outputRateOverride = (outID, outRate)
        }
        let status = CoreAudioHelpers.setNominalSampleRate(inRate, for: outID)
        logger.notice("Mic output rate request: device=\(outID, privacy: .public), from=\(outRate, privacy: .public), target=\(inRate, privacy: .public), status=\(status, privacy: .public)")
        // A rejected request leaves the rate unchanged, so waiting for it only
        // lengthens the mic gap (AirPods output refuses 24 kHz with 'nope').
        guard status == noErr else { return }
        for _ in 0 ..< 40 {
            if let now = CoreAudioHelpers.nominalSampleRate(for: outID),
               abs(now - inRate) < 1
            { break }
            usleep(25000)
        }
        let rateAfter = CoreAudioHelpers.nominalSampleRate(for: outID) ?? 0
        logger.notice("Mic output rate after request: device=\(outID, privacy: .public), actual=\(rateAfter, privacy: .public)")
    }

    /// Restores the output rate saved before this capture changed it.
    private func restoreOutputRate() {
        guard let override = outputRateOverride else { return }
        CoreAudioHelpers.setNominalSampleRate(override.originalRate, for: override.deviceID)
        outputRateOverride = nil
    }

    /// Connects a silent source node straight to `outputNode` (not through
    /// `mainMixerNode`) with sample rate forced to the VPIO input rate.
    private func attachSilentOutput(to engine: AVAudioEngine, inputRate: Double) {
        let output = engine.outputNode
        let hwChannels = max(1, output.outputFormat(forBus: 0).channelCount)
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: inputRate, channels: hwChannels
        ) else { return }

        let node = AVAudioSourceNode(format: format) { isSilence, _, _, bufList in
            isSilence.pointee = ObjCBool(true)
            let abl = UnsafeMutableAudioBufferListPointer(bufList)
            for buf in abl {
                if let data = buf.mData { memset(data, 0, Int(buf.mDataByteSize)) }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: output, format: format)
        silenceNode = node
    }

    /// Tears down the current engine. Crash-safe sequence based on WWDC19
    /// Session 510 ("What's New in AVAudioEngine"): VP toggling requires the
    /// engine to be in a **stopped** state. The previous code called
    /// `setVoiceProcessingEnabled(false)` while the engine was still running,
    /// which threw on every teardown — leaving VPIO enabled for dealloc.
    ///
    /// Correct order:
    ///   1. Remove the input tap (stop the real-time callback).
    ///   2. Stop the engine (required before VP can be toggled).
    ///   3. Disable voice processing (engine is stopped → succeeds).
    ///   4. Detach the silence node and nil out references.
    private func teardownEngine() {
        session?.invalidateTap()
        engineRoute = nil
        guard let eng = engine else {
            silenceNode = nil
            return
        }

        // 1. Invalidate before removal: an already queued callback may still
        //    arrive, but it no longer owns access to the recording session.
        eng.inputNode.removeTap(onBus: 0)

        // 2. Stop the engine. WWDC19-510: "Voice processing cannot be enabled
        //    dynamically … the engine needs to be in a stop state."
        if eng.isRunning { eng.stop() }

        // 3. Disable voice processing AFTER stop. The crash in Failure Mode A
        //    shows AVAudioEngine.dealloc hitting
        //    AUGraphNodeIOV3::DeallocateInputBlock on a node that still has
        //    VPIO enabled. Disabling VP while stopped tears down the
        //    AUVoiceProcessor graph cleanly under our control (not in dealloc).
        //    The previous code tried this before stop() — which always threw
        //    because VP toggling requires a stopped engine.
        do {
            try eng.inputNode.setVoiceProcessingEnabled(false)
            logger.notice("Teardown: voice processing disabled")
        } catch {
            // Not fatal — we're tearing down anyway, but a failure here means
            // VPIO is still enabled at dealloc, which risks the original crash.
            logger.error("Teardown: setVoiceProcessingEnabled(false) failed: \(error.localizedDescription, privacy: .public)")
        }

        // 4. Detach the silence node and nil out references.
        if let node = silenceNode { eng.detach(node) }
        silenceNode = nil
        engine = nil
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

    /// A configuration notification may arrive after VPIO starts but before its
    /// first buffer. Ignore it only if the current engine is still running. If it
    /// stopped, restart the existing graph without toggling voice processing;
    /// recreating that unit can reproduce the startup change indefinitely.
    /// AudioRecorder independently bounds the wait for the first written buffer.
    /// After audio delivery (a device change), restart the existing graph too;
    /// see `recoverEngineAfterConfigurationChange`.
    private func handleConfigurationChange(engineID: ObjectIdentifier) {
        engineQueue.async { [weak self] in
            guard let self, !isTearingDown, capturingFlag.load(ordering: .acquiring),
                  let engine, ObjectIdentifier(engine) == engineID else { return }

            let settled = session?.hasDeliveredBuffer ?? false
            let running = engine.isRunning
            logger.notice("Mic config change: running=\(running, privacy: .public), bufferDelivered=\(settled, privacy: .public)")

            if !settled, running {
                // Absorb: this is the VPIO startup-settle config change.
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

/// Pure audio-buffer operations used by the VPIO mic tap. Extracted from the
/// engine class so they can be unit-tested without hardware.
enum VPIOBufferHelper {
    /// Extracts channel 0 of a multichannel non-interleaved float PCM buffer
    /// into a mono buffer at the same sample rate. With VPIO, channel 0 is
    /// the processed/beamformed mono; the rest are raw-array reference feeds.
    static func extractChannel0(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(source.frameLength)
        guard frames > 0, let srcData = source.floatChannelData else { return nil }
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: source.format.sampleRate,
            channels: 1,
            interleaved: false
        ), let mono = AVAudioPCMBuffer(
            pcmFormat: monoFormat,
            frameCapacity: AVAudioFrameCount(frames)
        ) else { return nil }
        mono.frameLength = AVAudioFrameCount(frames)
        guard let dst = mono.floatChannelData?[0] else { return nil }
        dst.update(from: srcData[0], count: frames)
        return mono
    }

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
