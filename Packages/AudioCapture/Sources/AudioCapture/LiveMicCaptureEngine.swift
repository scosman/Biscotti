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
    #if DEBUG
        nonisolated(unsafe) static var verboseDiagnostics = true
    #endif

    private let encoder: EncoderSettings
    private let processingFormat: AVAudioFormat

    /// Atomic file ref (bit-pattern of the opaque pointer, 0 = nil).
    /// Lock-free so the real-time tap can read without blocking.
    private let atomicFileRef = Atomic<UInt>(0)

    /// Serializes the tap's `ExtAudioFileWrite` against `closeExtFile()`'s
    /// `ExtAudioFileDispose`. The tap takes it with `trylock` (never blocks on
    /// the real-time thread); `closeExtFile` takes it with `lock` so dispose
    /// waits for any in-flight write. Without this barrier, `engine.stop()` /
    /// `removeTap` is not guaranteed to drain an in-flight render callback, so
    /// dispose could free the AAC encoder while the audio thread is mid-write
    /// — a heap use-after-free.
    private var _fileLock = os_unfair_lock()

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
    private var cachedConverter: AVAudioConverter?
    private var cachedConverterSourceHash: Int = 0

    var onUnrecoverableError: (@Sendable (Error) -> Void)?

    /// Callback fired exactly once when the first tap buffer is delivered.
    /// Argument: host-clock anchor (seconds) — the recording's t=0.
    /// Route-change rebuilds do NOT re-fire this.
    ///
    /// **Intentional unsynchronised access:** this `var` is written by
    /// `setOnFirstBuffer` (from the `AudioRecorder` actor) and read on the
    /// real-time audio thread in `notifyFirstBufferIfNeeded`. A lock is NOT
    /// used because taking one on the audio thread risks priority inversion
    /// and glitches. The race is benign: Apple-silicon pointer-sized loads
    /// are atomic (no torn read), `didNotifyFirstBuffer` prevents double-fire,
    /// and optional chaining handles the nil case. This mirrors AudioLab's
    /// validated `VPIOMicCapture.onStarted` pattern. Do NOT "fix" with a lock.
    private var onFirstBuffer: (@Sendable (Double) -> Void)?

    func setOnFirstBuffer(_ callback: (@Sendable (Double) -> Void)?) {
        onFirstBuffer = callback
    }

    /// Guards one-shot firing of `onFirstBuffer`. Once set, route-change
    /// engine rebuilds do not reset it — t=0 is the very first buffer.
    private let didNotifyFirstBuffer = Atomic<Bool>(false)

    /// Set to `true` once the real-time tap delivers a buffer for the current
    /// engine build. Cleared on each `buildAndStartEngineOrThrow`. Read by
    /// `handleConfigurationChange` (on `engineQueue`) to decide whether to
    /// absorb or honour a config-change. Written atomically from the audio
    /// thread, read on `engineQueue` — Atomic avoids any data race.
    private let currentEngineBufferDelivered = Atomic<Bool>(false)

    init(encoder: EncoderSettings = .voice) {
        self.encoder = encoder
        processingFormat = encoder.processingFormat
    }

    // MARK: - CaptureEngine conformance

    func start(writingTo url: URL) async throws {
        guard !capturingFlag.load(ordering: .acquiring) else { return }

        // New session: re-arm the one-shot first-buffer anchor. A start() can
        // legitimately run again after a *failed* start (the recorder stays
        // retryable), so this must reset — otherwise the retry never re-fires
        // the anchor and two-track alignment silently degrades. NOT reset on
        // reconnect: t=0 is the first buffer of the session, not each rebuild.
        didNotifyFirstBuffer.store(false, ordering: .releasing)

        let file = try VPIOFileHelper.createExtAudioFile(
            url: url, encoder: encoder, processingFormat: processingFormat
        )
        setExtFile(file)
        capturingFlag.store(true, ordering: .releasing)

        // Run the initial engine build on engineQueue via a continuation so
        // we don't block a cooperative thread. The build (including the ~1 s
        // output-device reclock poll) completes before start() returns, so
        // AudioRecorder can start the system engine against a stable rate.
        // Route-change rebuilds remain fire-and-forget via handleConfigurationChange.
        //
        // The config-change observer is installed AFTER the engine starts,
        // not before, to prevent a race: enabling VPIO changes the audio
        // graph, which can fire AVAudioEngineConfigurationChange. If the
        // observer is active during the initial build, that notification
        // queues a teardown+rebuild on engineQueue that runs immediately
        // after the build — destroying the engine before it delivers any
        // mic buffers. Under Release optimizations the tighter timing
        // makes this race deterministic, causing a first-buffer timeout
        // and silent recording failure.
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                engineQueue.async { [self] in
                    isTearingDown = false
                    do {
                        try buildAndStartEngineOrThrow()
                        installConfigChangeObserver()
                        cont.resume()
                    } catch {
                        teardownEngine()
                        restoreOutputRate()
                        cont.resume(throwing: error)
                    }
                }
            }
        } catch {
            capturingFlag.store(false, ordering: .releasing)
            closeExtFile()
            throw CaptureError.micEngineFailed(
                error.localizedDescription
            )
        }
    }

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
                closeExtFile()
                cont.resume()
            }
        }
    }

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
                    teardownEngine()
                    restoreOutputRate()
                    closeExtFile()
                    capturingFlag.store(false, ordering: .releasing)
                    cont.resume(throwing: CaptureError.micEngineFailed(
                        error.localizedDescription
                    ))
                }
            }
        }
    }

    deinit {
        // Remove the observer first so no config-change fires during teardown.
        removeConfigChangeObserver()
        teardownEngine()
        restoreOutputRate()
        closeExtFile()
    }

    // MARK: - Engine lifecycle (engineQueue)

    /// Throwing core of the engine build (initial start + route-change).
    private func buildAndStartEngineOrThrow() throws {
        guard capturingFlag.load(ordering: .acquiring) else { return }

        // Reset the per-build buffer-delivered flag so the config-change
        // handler knows this is a fresh engine that hasn't settled yet.
        currentEngineBufferDelivered.store(false, ordering: .releasing)

        ensureOutputRateMatchesInput()

        let newEngine = AVAudioEngine()
        engine = newEngine // store early so teardownEngine() works on failure
        let input = newEngine.inputNode

        try input.setVoiceProcessingEnabled(true)
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(
            enableAdvancedDucking: false, duckingLevel: .min
        )

        let tapFormat = input.outputFormat(forBus: 0)
        #if DEBUG
            if Self.verboseDiagnostics {
                logger.info("[diag] VPIO input tap: rate=\(tapFormat.sampleRate) ch=\(tapFormat.channelCount)")
            }
        #endif
        attachSilentOutput(to: newEngine, inputRate: tapFormat.sampleRate)

        input.installTap(
            onBus: 0, bufferSize: 1024, format: tapFormat
        ) { [weak self] buffer, when in
            self?.handleTap(buffer: buffer, when: when)
        }

        newEngine.prepare()
        try newEngine.start()
    }

    /// Non-throwing wrapper for route-change rebuilds.
    private func buildAndStartEngine(context: String) {
        do {
            try buildAndStartEngineOrThrow()
        } catch {
            logger.error("VPIO engine setup failed (\(context)): \(error.localizedDescription)")
            teardownEngine()
            restoreOutputRate()
            closeExtFile()
            capturingFlag.store(false, ordering: .releasing)
            // Dispatch off engineQueue to avoid deadlock if the handler
            // calls stop() (which does engineQueue.sync).
            let handler = onUnrecoverableError
            DispatchQueue.global().async { handler?(error) }
        }
    }

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
        CoreAudioHelpers.setNominalSampleRate(inRate, for: outID)
        for _ in 0 ..< 40 {
            if let now = CoreAudioHelpers.nominalSampleRate(for: outID),
               abs(now - inRate) < 1
            { break }
            usleep(25000)
        }
        #if DEBUG
            if Self.verboseDiagnostics {
                let rateAfter = CoreAudioHelpers.nominalSampleRate(for: outID) ?? 0
                let name = CoreAudioHelpers.deviceName(for: outID) ?? "unknown"
                let msg = "output=\"\(name)\" id=\(outID) before=\(outRate) inputTarget=\(inRate) after=\(rateAfter)"
                logger.info("[diag] rate match: \(msg)")
            }
        #endif
    }

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
        guard let eng = engine else {
            silenceNode = nil
            cachedConverter = nil
            cachedConverterSourceHash = 0
            return
        }

        // 1. Remove the input tap first — this stops the real-time callback
        //    from firing and prevents new writes to the file.
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
        cachedConverter = nil
        cachedConverterSourceHash = 0
    }

    // MARK: - Config-change observer

    /// Installs the config-change observer. Must run on `engineQueue`
    /// (same as `removeConfigChangeObserver`) so `configObserver` is
    /// accessed from a single serial context.
    private func installConfigChangeObserver() {
        // object: nil is intentional. buildAndStartEngine creates a fresh
        // AVAudioEngine on every rebuild, so scoping to a specific instance
        // would go stale after the first route-change rebuild. This is safe:
        // LiveMicCaptureEngine is the only AVAudioEngine in the package (the
        // system engine uses Core Audio taps, not AVAudioEngine).
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] _ in self?.handleConfigurationChange() }
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

    /// Handles `AVAudioEngineConfigurationChange`. The key insight: enabling
    /// VPIO creates an aggregate device and reconfigures IO scopes, which
    /// fires a config-change notification ~50-100ms AFTER `engine.start()`.
    /// This is a one-shot settling event, NOT a genuine route change. If we
    /// tear down the engine on this notification, it never delivers a buffer
    /// and mic recording silently fails.
    ///
    /// Strategy: absorb config-change notifications that arrive before the
    /// current engine has delivered its first tap buffer (the "startup-settle
    /// window"). Once the first buffer arrives we know the VPIO graph is
    /// stable and any subsequent config-change is a genuine route change that
    /// warrants a rebuild.
    private func handleConfigurationChange() {
        engineQueue.async { [weak self] in
            guard let self, !isTearingDown else { return }

            let settled = currentEngineBufferDelivered.load(ordering: .acquiring)

            if !settled {
                // Absorb: this is the VPIO startup-settle config change.
                logger.info("Config-change absorbed during startup settle (no buffer yet)")
                return
            }

            logger.notice("Config-change honoured — rebuilding (route change)")
            teardownEngine()
            buildAndStartEngine(context: "route change")
        }
    }

    // MARK: - Tap (real-time audio thread)

    private func handleTap(buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        // Mark that this engine build has delivered a buffer. This arms the
        // config-change handler to honour subsequent notifications (the
        // startup-settle window is over). The store is idempotent after the
        // first buffer. The `.releasing` store pairs with the `.acquiring`
        // load in `handleConfigurationChange` for a proper release/acquire
        // edge, though even a relaxed store would suffice for correctness
        // here: the engineQueue reader only needs eventual visibility (a
        // single extra absorbed notification is harmless; a missed genuine
        // route change is impossible because route changes fire repeatedly
        // until honoured).
        if !currentEngineBufferDelivered.load(ordering: .relaxed) {
            currentEngineBufferDelivered.store(true, ordering: .releasing)
        }

        notifyFirstBufferIfNeeded(when)
        guard let mono = VPIOBufferHelper.extractChannel0(buffer) else { return }

        let targetFormat = processingFormat
        let bufferToWrite: AVAudioPCMBuffer
        if mono.format.sampleRate == targetFormat.sampleRate {
            bufferToWrite = mono
        } else {
            guard let converter = converterForSource(mono.format),
                  let converted = VPIOBufferHelper.convert(
                      mono, to: targetFormat, using: converter
                  )
            else { return }
            bufferToWrite = converted
        }

        // Serialize the file write against closeExtFile()'s dispose. `trylock`
        // (never block) on the real-time thread: if teardown holds the lock we
        // simply drop this buffer — we're stopping anyway, and a write into a
        // disposed AAC encoder would corrupt the heap. The file ref is loaded
        // *inside* the lock so it can't be disposed between load and write.
        guard os_unfair_lock_trylock(&_fileLock) else { return }
        defer { os_unfair_lock_unlock(&_fileLock) }
        guard let file = currentExtFile() else { return }
        VPIOBufferHelper.writeBuffer(bufferToWrite, to: file)
    }

    /// Fires `onFirstBuffer` exactly once with the host-clock seconds of the
    /// first delivered buffer. Derives the anchor from `when.hostTime` via
    /// `AudioConvertHostTimeToNanos` -- the same clock base the system engine
    /// uses to pad the system track, so the two stay aligned.
    private func notifyFirstBufferIfNeeded(_ when: AVAudioTime) {
        guard !didNotifyFirstBuffer.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let anchor: Double = if when.isHostTimeValid {
            Double(AudioConvertHostTimeToNanos(when.hostTime)) / 1_000_000_000
        } else {
            0
        }
        logger.info("First mic buffer delivered -- anchor=\(anchor)s")
        onFirstBuffer?(anchor)
    }

    private func converterForSource(_ sourceFormat: AVAudioFormat) -> AVAudioConverter? {
        let sourceHash = sourceFormat.hash
        if sourceHash == cachedConverterSourceHash, let converter = cachedConverter {
            return converter
        }
        guard let converter = AVAudioConverter(
            from: sourceFormat, to: processingFormat
        ) else {
            logger.error("Failed to build AVAudioConverter for mic resampling")
            return nil
        }
        cachedConverter = converter
        cachedConverterSourceHash = sourceHash
        return converter
    }
}

// MARK: - File handle (lock-free, safe for real-time thread)

extension LiveMicCaptureEngine {
    private func setExtFile(_ file: ExtAudioFileRef?) {
        let bits = file.map { UInt(bitPattern: $0) } ?? 0
        atomicFileRef.store(bits, ordering: .releasing)
    }

    private func closeExtFile() {
        // Take the lock so any in-flight tap write completes before dispose
        // (see `_fileLock`). Zero the ref inside the lock so a tap that has
        // not yet taken the lock observes nil and skips its write.
        os_unfair_lock_lock(&_fileLock)
        defer { os_unfair_lock_unlock(&_fileLock) }
        let bits = atomicFileRef.exchange(0, ordering: .acquiringAndReleasing)
        if bits != 0, let ptr = OpaquePointer(bitPattern: bits) {
            ExtAudioFileDispose(ptr)
        }
    }

    private func currentExtFile() -> ExtAudioFileRef? {
        let bits = atomicFileRef.load(ordering: .acquiring)
        guard bits != 0 else { return nil }
        return OpaquePointer(bitPattern: bits)
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
