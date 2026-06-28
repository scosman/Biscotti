// swiftlint:disable file_length type_body_length
import AudioToolbox
import CoreAudio
import Foundation

@preconcurrency import AVFoundation

/// Abstraction over the two microphone-capture strategies so
/// `RecordingCoordinator` can A/B them without caring which is live: the
/// original `AVCaptureSession` path (`MicCapture`) and the VoiceProcessingIO /
/// `AVAudioEngine` path (`VPIOMicCapture`).
///
/// Shared contract:
/// - `start()` is *asynchronous*: it returns once capture has been requested;
///   the mic's input IO going live is signalled later via `onStarted`.
/// - `onStarted` fires **exactly once** for the whole recording, with the
///   host-clock time (seconds, `AudioConvertHostTimeToNanos` base) of the first
///   delivered buffer — the recording's t=0 anchor used to align the system
///   track.
/// - Async/route-change failures surface via `onUnrecoverableError` (off the
///   main thread).
protocol MicCapturing: AnyObject {
    var onStarted: (@Sendable (Double) -> Void)? { get set }
    var onUnrecoverableError: (@Sendable (Error) -> Void)? { get set }
    var isCapturing: Bool { get }
    func start() throws
    func stop()
}

extension MicCapture: MicCapturing {}

/// Microphone capture via **VoiceProcessingIO** (`AVAudioEngine`
/// `inputNode.setVoiceProcessingEnabled(true)`).
///
/// Why this exists: the AVCaptureSession path (`MicCapture`) records the
/// built-in mic's *raw* 3-channel beamformer array (~−48 dBFS, near-silent
/// during meetings — see `specs/research/audio/mic_capture_level_findings.md`). The
/// loud, normalised, noise-suppressed, echo-cancelled **mono** only exists
/// *after* Apple's voice-processing pipeline. Becoming a first-class VPIO client
/// is the only route to it.
///
/// Known hazards baked into this implementation (see NOTES.md / phase 9
/// findings):
/// - **VPIO has faulted on this hardware before** (`Cannot retrieve
///   theDeviceBoardID` + `failed to run downlink DSP (state fault)`). So this is
///   also the *spike*: engine setup is heavily logged and any failure to enable
///   VP / start the engine is reported via `onUnrecoverableError`; if VP starts
///   but the DSP is dead, the no-buffer watchdog fires within ~2 s. Either way
///   the logs say plainly whether VPIO is viable on the current OS.
/// - **VPIO silently presents a ~9-channel input format.** We extract channel 0
///   manually (`MicCaptureFileHelper.extractChannel0`) — never `AVAudioConverter`
///   for the channel reduction (it crashed on the real-time thread).
/// - **VPIO is a duplex unit:** its input may not produce buffers unless the
///   output (downlink) side is also cycling, so we drive a *silent* output node
///   (muted mixer) to keep the IO running.
/// - **Route changes destroy the device** (a meeting starting *is* a route
///   change). We rebuild the engine on `.AVAudioEngineConfigurationChange`,
///   keeping the same output file open.
///
/// Diagnostics mirror `MicCapture`: per-subsystem `Log.mic`, a 2 s heartbeat
/// with buffer/frame counters, per-source-channel input peaks + output peak, and
/// stall / no-data / no-write watchdogs. The peaks are the success test — output
/// peak should rise to a normal speaking level (> ~0.05) and *stay* loud while a
/// meeting app holds the mic.
final class VPIOMicCapture: MicCapturing, @unchecked Sendable {
    /// Drive a muted silent output node so the VPIO **duplex** unit's downlink
    /// (output) half runs with valid timestamps.
    ///
    /// **Hardware findings (2026-06-08):**
    /// - Run 1, output ON via a 44.1 kHz mixer while the mic input was 48 kHz →
    ///   init failed with `-10875` ("client-side input and output formats do not
    ///   match"): VPIO is one unit on a single IO clock and can't span two rates.
    /// - Run 2, output OFF (input-only) → init OK and levels good, but the
    ///   downlink faulted every cycle (`failed to run downlink DSP (I/O fault)` /
    ///   `audio time stamp does not have valid sample time`) because nothing
    ///   rendered to the output → the shared IO cadence stuttered → **choppy
    ///   mic with gaps**.
    ///
    /// So we drive the output **and** first raise the default output device's
    /// nominal rate to the input's (`ensureOutputRateMatchesInput`) so the two
    /// duplex scopes share one rate — fixing both the `-10875` and the downlink
    /// fault. The output device rate is restored on stop.
    private static let driveSilentOutput = true

    private static let heartbeatInterval = 2

    private let fileURL: URL

    private let fileLock = NSLock() // guards extFile
    private var extFile: ExtAudioFileRef?
    private let lock = NSLock()
    private var _isCapturing = false

    /// Engine lifecycle queue (build / start / reconfigure / stop). Off main.
    private let engineQueue = DispatchQueue(label: "com.audiolab.vpiomic.engine")
    private var isTearingDown = false
    private var engine: AVAudioEngine?
    private var silenceNode: AVAudioSourceNode?
    private var configChangeObserver: NSObjectProtocol?

    /// Set when we raise the default **output** device's sample rate to match the
    /// input's (so the VPIO duplex unit can drive its downlink): the device and
    /// its original rate, so `stop()` can restore it. nil ⇒ no override active.
    /// Touched only on `engineQueue`.
    private var outputRateOverride: (deviceID: AudioObjectID, originalRate: Double)?

    private var cachedConverter: AVAudioConverter?
    private var cachedConverterSourceHash: Int = 0

    // MARK: - Diagnostics

    /// Sample-pipeline counters. Mutated on the real-time tap thread, snapshotted
    /// on the heartbeat queue — guarded by `statsLock`.
    private struct Stats {
        var buffersReceived = 0
        var framesWritten = 0
        var extractFailures = 0
        var convertFailures = 0
        var writeFailures = 0
        var lastSourceFormat = "?"
        /// Peak |sample| of the written (mono 24 kHz) audio over the heartbeat
        /// window. The headline number: low while frames climb ⇒ still capturing
        /// quiet/silent audio; rising to a speaking level ⇒ VPIO is delivering
        /// the processed mono we want.
        var outputPeak: Float = 0
        /// Per-source-channel peak |sample| of the raw VPIO tap. Channel 0 should
        /// carry the processed voice; the rest are reference/array feeds.
        var channelPeaks: [Float] = []
    }

    private let statsLock = NSLock()
    private var stats = Stats()

    private let heartbeatQueue = DispatchQueue(label: "com.audiolab.vpiomic.heartbeat")
    private var heartbeatTimer: DispatchSourceTimer?
    private var heartbeatTick = 0
    private var lastBuffersReceived = 0
    private var stallReported = false
    private var writeStallReported = false

    /// Called off the main thread on unrecoverable errors (VP enable failure,
    /// engine start failure, failed engine rebuild after a route change).
    var onUnrecoverableError: (@Sendable (Error) -> Void)?

    /// Called off the main thread exactly once, when the first tap buffer is
    /// delivered. Argument: the host-clock time (seconds) of that buffer — the
    /// recording's t=0 (same clock base the system tap aligns against).
    var onStarted: (@Sendable (Double) -> Void)?
    private var didNotifyStarted = false // guarded by `lock`

    var isCapturing: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isCapturing
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func start() throws {
        lock.lock()
        guard !_isCapturing else { lock.unlock(); return }
        _isCapturing = true
        lock.unlock()

        Log.mic.event("VPIO start() requested → file=\(fileURL.lastPathComponent)")
        Log.mic.event("input state at start: \(CoreAudioHelpers.inputDiagnosticsSnapshot())")

        // Create the output file up front (synchronously) so a creation failure
        // throws to the coordinator before we claim to be recording — matching
        // the AVCaptureSession path's contract.
        let file = try MicCaptureFileHelper.createExtAudioFile(
            url: fileURL, clientFormat: EncoderSettings.processingFormat
        )
        setExtFile(file)
        Log.mic.event("created ExtAudioFile (client \(EncoderSettings.describe(EncoderSettings.processingFormat)))")

        installConfigChangeObserver()

        engineQueue.async { [weak self] in
            self?.buildAndStartEngine(context: "initial start")
        }
    }

    func stop() {
        lock.lock()
        guard _isCapturing else { lock.unlock(); return }
        _isCapturing = false
        lock.unlock()

        Log.mic.event("VPIO stop() requested")
        removeConfigChangeObserver()
        engineQueue.async { [weak self] in
            guard let self else { return }
            isTearingDown = true
            teardownEngine()
            restoreOutputRate()
            closeExtFile()
            let snap = snapshotStats()
            Log.mic.event(
                "VPIO stopped. totals: buffers=\(snap.buffersReceived) framesWritten=\(snap.framesWritten) " +
                    "extractFail=\(snap.extractFailures) convertFail=\(snap.convertFailures) " +
                    "writeFail=\(snap.writeFailures)"
            )
        }
    }

    deinit {
        removeConfigChangeObserver()
        heartbeatTimer?.cancel()
        teardownEngine()
        restoreOutputRate()
        if let file = extFile { ExtAudioFileDispose(file) }
    }

    // MARK: - Engine lifecycle (engineQueue)

    /// Builds a fresh `AVAudioEngine` with voice processing enabled, installs the
    /// tap, drives a silent output, and starts it. Used for both the initial
    /// start and rebuilds after a route change. Heavily logged — this doubles as
    /// the VPIO viability spike. On any failure: tear down, close the file,
    /// report `onUnrecoverableError`.
    private func buildAndStartEngine(context: String) {
        // A stop() that raced in before this queue item ran already flipped us to
        // not-capturing (its teardown/closeExtFile runs after us on this serial
        // queue) — don't bother building an engine we're about to discard.
        guard isCapturing else {
            Log.mic.event("VPIO engine build (\(context)) skipped — capture already stopped")
            return
        }
        Log.mic.event("=== VPIO engine build (\(context)) ===")
        do {
            // VPIO is a duplex unit on one IO clock: before building, make the
            // default output device share the input's rate so we can drive a
            // valid downlink without a -10875 mismatch (and so the downlink
            // stops faulting → no choppiness).
            if Self.driveSilentOutput {
                ensureOutputRateMatchesInput()
            }

            let engine = AVAudioEngine()
            // Store before the fallible setup so the catch path's teardownEngine()
            // can stop it / remove the tap / detach the silence node.
            self.engine = engine
            let input = engine.inputNode

            Log.mic.event("enabling voice processing on inputNode…")
            try input.setVoiceProcessingEnabled(true)
            // Don't duck other audio (we're only listening, not playing a call).
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: false, duckingLevel: .min
            )

            // Query the format VPIO actually presents *after* enabling VP — this
            // is the ~9-channel surprise. The tap uses it verbatim; we extract
            // ch0 downstream.
            let tapFormat = input.outputFormat(forBus: 0)
            Log.mic.event("VPIO enabled OK. input tap format: \(EncoderSettings.describe(tapFormat))")

            if Self.driveSilentOutput {
                attachSilentOutput(to: engine, inputRate: tapFormat.sampleRate)
            }

            input.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, when in
                self?.handleTap(buffer: buffer, when: when)
            }
            Log.mic.event("installed input tap (bufferSize=1024)")

            engine.prepare()
            try engine.start()
            Log.mic.event("engine.start() OK — isRunning=\(engine.isRunning). Waiting for first buffer…")

            startHeartbeat()
        } catch {
            Log.mic.err("VPIO ENGINE SETUP FAILED (\(context)): \(error.localizedDescription)")
            if (error as NSError).code == -10875 {
                Log.mic.err(
                    "↳ -10875 (FormatNotSupported): the VPIO duplex unit can't span the default input and output " +
                        "device sample rates. Run input-only (driveSilentOutput=false) or match the output device's " +
                        "nominal rate to the input's before driving an output node."
                )
            } else {
                Log.mic.err(
                    "↳ If this is a board-ID / downlink-DSP 'state fault', VPIO is not viable on this OS/hardware — " +
                        "fall back to software makeup gain on the AVCaptureSession path (set useVoiceProcessingMic=false)."
                )
            }
            teardownEngine()
            restoreOutputRate()
            closeExtFile()
            setNotCapturing()
            onUnrecoverableError?(error)
        }
    }

    /// Raises the default **output** device's nominal sample rate to match the
    /// default **input**'s, so the VPIO duplex unit's two scopes share one IO
    /// clock. Records the original rate (once) for restoration on stop. The HAL
    /// applies the change asynchronously, so we poll until it reflects (or time
    /// out). Runs on `engineQueue`. No-op if the rates already match.
    private func ensureOutputRateMatchesInput() {
        guard let inID = CoreAudioHelpers.defaultInputDeviceID(),
              let inRate = CoreAudioHelpers.nominalSampleRate(for: inID),
              let outID = CoreAudioHelpers.defaultOutputDeviceID(),
              let outRate = CoreAudioHelpers.nominalSampleRate(for: outID)
        else {
            Log.mic.warn("could not read input/output device rates — skipping rate match")
            return
        }
        guard abs(inRate - outRate) > 1 else {
            Log.mic.event("output rate \(Int(outRate))Hz already matches input \(Int(inRate))Hz — no change")
            return
        }
        if outputRateOverride == nil {
            outputRateOverride = (outID, outRate)
        }
        let status = CoreAudioHelpers.setNominalSampleRate(inRate, for: outID)
        Log.mic.event(
            "raising output device \(outID) rate \(Int(outRate))Hz → \(Int(inRate))Hz for VPIO duplex " +
                "(status \(osStatusString(status)))"
        )
        for _ in 0 ..< 40 { // up to ~1s for the async HAL change to apply
            if let now = CoreAudioHelpers.nominalSampleRate(for: outID), abs(now - inRate) < 1 {
                Log.mic.event("output device confirmed at \(Int(now))Hz")
                return
            }
            usleep(25_000)
        }
        Log.mic.warn("output device rate did not confirm \(Int(inRate))Hz within ~1s — proceeding anyway")
    }

    /// Restores the output device's original sample rate if we overrode it.
    /// Idempotent; runs on `engineQueue` (and from `deinit`).
    private func restoreOutputRate() {
        guard let override = outputRateOverride else { return }
        let status = CoreAudioHelpers.setNominalSampleRate(override.originalRate, for: override.deviceID)
        Log.mic.event(
            "restored output device \(override.deviceID) rate → \(Int(override.originalRate))Hz " +
                "(status \(osStatusString(status)))"
        )
        outputRateOverride = nil
    }

    /// Drives a silence-rendering source node so the VPIO duplex unit's downlink
    /// (output) half runs with valid timestamps.
    ///
    /// Connects **straight to the output node** (NOT through `mainMixerNode`,
    /// whose output bus has a software-default 44.1 kHz format that ignores the
    /// hardware device rate — routing through it pinned the VPIO output scope to
    /// 44.1 kHz while the input was 48 kHz → `-10875`). Crucially the silence
    /// format's **sample rate is forced to the VPIO input rate** (`inputRate`),
    /// not read back from the output node (whose reported format lags the device
    /// change). That guarantees the duplex unit's input and output client scopes
    /// share one rate. Channels follow the output node's hardware to avoid a
    /// channel-mismatch on connect. `isSilence` + zero-filled buffers ⇒ nothing
    /// audible. Must run before `engine.start()`.
    private func attachSilentOutput(to engine: AVAudioEngine, inputRate: Double) {
        let output = engine.outputNode
        let hwChannels = max(1, output.outputFormat(forBus: 0).channelCount)
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: inputRate, channels: hwChannels
        ) else {
            Log.mic.warn("could not build a \(Int(inputRate))Hz/\(hwChannels)ch silent-output format — skipping")
            return
        }
        let node = AVAudioSourceNode(format: format) { isSilence, _, _, audioBufferList in
            isSilence.pointee = ObjCBool(true)
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in abl {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: output, format: format)
        silenceNode = node
        Log.mic.event(
            "attached silent-output driver (\(EncoderSettings.describe(format))) → outputNode " +
                "(rate forced to VPIO input \(Int(inputRate))Hz) to cycle the downlink"
        )
    }

    /// Tears down the current engine (stop, remove tap, detach silence). Leaves
    /// the output file open. Runs on `engineQueue`.
    private func teardownEngine() {
        stopHeartbeat()
        if let engine {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
            if let silenceNode { engine.detach(silenceNode) }
        }
        silenceNode = nil
        engine = nil
        cachedConverter = nil
        cachedConverterSourceHash = 0
    }

    /// `.AVAudioEngineConfigurationChange` handler. A route change (call start,
    /// AirPods, default-device switch) has invalidated the device AVAudioEngine
    /// bound to — and a meeting *starting* is exactly this. The engine has
    /// stopped itself; rebuild from scratch, keeping the file open. `onStarted`
    /// is **not** re-fired (t=0 is anchored to the very first buffer).
    private func handleConfigurationChange() {
        Log.device.event("AVAudioEngineConfigurationChange — rebuilding VPIO engine")
        Log.device.event("new input state: \(CoreAudioHelpers.inputDiagnosticsSnapshot())")
        engineQueue.async { [weak self] in
            guard let self, !isTearingDown else { return }
            teardownEngine()
            buildAndStartEngine(context: "route change")
        }
    }

    // MARK: - Tap (real-time audio thread)

    private func handleTap(buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        notifyStartedIfNeeded(when)
        mutateStats { $0.buffersReceived += 1 }

        guard let file = currentExtFile() else { return }

        if recordSourceFormatIfChanged(buffer.format) {
            logChannelPeaks(buffer)
        }

        // Track per-source-channel peaks every buffer so the heartbeat shows live
        // levels during speech (the one-shot log above lands at t=0 silence).
        let srcPeaks = MicCaptureFileHelper.channelPeaks(of: buffer)
        mutateStats { stats in
            if stats.channelPeaks.count == srcPeaks.count {
                for index in srcPeaks.indices {
                    stats.channelPeaks[index] = max(stats.channelPeaks[index], srcPeaks[index])
                }
            } else {
                stats.channelPeaks = srcPeaks
            }
        }

        // VPIO puts the processed mono on channel 0. Take it verbatim (do NOT
        // average the reference channels back in), then resample mono→mono.
        guard let mono = MicCaptureFileHelper.extractChannel0(buffer) else {
            mutateStats { $0.extractFailures += 1 }
            return
        }

        let targetFormat = EncoderSettings.processingFormat
        let bufferToWrite: AVAudioPCMBuffer
        if mono.format.sampleRate == targetFormat.sampleRate {
            bufferToWrite = mono
        } else {
            guard let converter = converterForSource(mono.format),
                  let converted = MicCaptureFileHelper.convert(mono, to: targetFormat, using: converter)
            else {
                mutateStats { $0.convertFailures += 1 }
                return
            }
            bufferToWrite = converted
        }

        let outPeak = MicCaptureFileHelper.peak(of: bufferToWrite)
        let status = MicCaptureFileHelper.writeBuffer(bufferToWrite, to: file)
        if status == noErr {
            mutateStats {
                $0.framesWritten += Int(bufferToWrite.frameLength)
                $0.outputPeak = max($0.outputPeak, outPeak)
            }
        } else {
            mutateStats { $0.writeFailures += 1 }
        }
    }

    /// Fires `onStarted` exactly once with the host-clock seconds of the first
    /// buffer. Derives the anchor from `when.hostTime` via
    /// `AudioConvertHostTimeToNanos` — the same clock base `SystemAudioCapture`
    /// uses to pad the system track, so the two stay aligned. Falls back to 0 if
    /// the host time is invalid (alignment padding is then skipped).
    private func notifyStartedIfNeeded(_ when: AVAudioTime) {
        lock.lock()
        if didNotifyStarted { lock.unlock(); return }
        didNotifyStarted = true
        lock.unlock()

        let anchor: Double
        if when.isHostTimeValid {
            anchor = Double(AudioConvertHostTimeToNanos(when.hostTime)) / 1_000_000_000
        } else {
            anchor = 0
        }
        Log.mic.event("FIRST VPIO mic buffer delivered — anchor=\(anchor)s. Mic IO is live.")
        onStarted?(anchor)
    }

    private func logChannelPeaks(_ buffer: AVAudioPCMBuffer) {
        let peaks = MicCaptureFileHelper.channelPeaks(of: buffer)
        let desc = peaks.enumerated()
            .map { "ch\($0.offset)=\(String(format: "%.4f", $0.element))" }
            .joined(separator: " ")
        Log.mic.event("VPIO source channel peaks: \(desc) (frames=\(buffer.frameLength))")
    }

    @discardableResult
    private func recordSourceFormatIfChanged(_ format: AVAudioFormat) -> Bool {
        let desc = EncoderSettings.describe(format)
        let changed = mutateStats { stats -> Bool in
            guard stats.lastSourceFormat != desc else { return false }
            stats.lastSourceFormat = desc
            return true
        }
        if changed {
            Log.mic.event("VPIO mic source format: \(desc)")
        }
        return changed
    }

    private func converterForSource(_ sourceFormat: AVAudioFormat) -> AVAudioConverter? {
        let sourceHash = sourceFormat.hash
        if sourceHash == cachedConverterSourceHash, let converter = cachedConverter {
            return converter
        }
        let targetFormat = EncoderSettings.processingFormat
        let sourceDesc = EncoderSettings.describe(sourceFormat)
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            Log.mic.err("VPIO failed to build AVAudioConverter from \(sourceDesc)")
            return nil
        }
        Log.mic.event("VPIO built converter \(sourceDesc) → \(EncoderSettings.describe(targetFormat))")
        cachedConverter = converter
        cachedConverterSourceHash = sourceHash
        return converter
    }

    // MARK: - Heartbeat / watchdog

    private func startHeartbeat() {
        stopHeartbeat()
        mutateStats { $0 = Stats() }
        heartbeatQueue.sync {
            heartbeatTick = 0
            lastBuffersReceived = 0
            stallReported = false
            writeStallReported = false
        }
        let timer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        timer.schedule(
            deadline: .now() + .seconds(Self.heartbeatInterval),
            repeating: .seconds(Self.heartbeatInterval)
        )
        timer.setEventHandler { [weak self] in self?.heartbeat() }
        heartbeatTimer = timer
        timer.resume()
        Log.mic.event("VPIO heartbeat started (\(Self.heartbeatInterval)s interval)")
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    /// Runs on `heartbeatQueue`. Logs a counter summary and raises watchdog
    /// faults for: (1) the input never delivers a buffer (the most likely VPIO
    /// DSP-fault signature), (2) it delivers some then stalls, (3) buffers arrive
    /// but none reach disk.
    private func heartbeat() {
        heartbeatTick += 1
        let elapsed = heartbeatTick * Self.heartbeatInterval
        let snap = mutateStats { stats -> Stats in
            let copy = stats
            stats.outputPeak = 0
            stats.channelPeaks = []
            return copy
        }
        let delta = snap.buffersReceived - lastBuffersReceived
        lastBuffersReceived = snap.buffersReceived

        Log.mic.event(
            "VPIO heartbeat t≈\(elapsed)s buffers=\(snap.buffersReceived)(+\(delta)) " +
                "framesWritten=\(snap.framesWritten) outPeak=\(String(format: "%.4f", snap.outputPeak)) " +
                "extractFail=\(snap.extractFailures) convertFail=\(snap.convertFailures) " +
                "writeFail=\(snap.writeFailures) src=[\(snap.lastSourceFormat)]"
        )

        let chDesc = snap.channelPeaks.isEmpty
            ? "n/a"
            : snap.channelPeaks.enumerated()
            .map { "ch\($0.offset)=\(String(format: "%.4f", $0.element))" }
            .joined(separator: " ")
        Log.mic.event("VPIO heartbeat src channel peaks: \(chDesc)")

        let flowing = delta > 0
        if flowing {
            stallReported = false
        } else if !stallReported {
            stallReported = true
            if snap.buffersReceived == 0 {
                Log.mic.err(
                    "WATCHDOG: NO VPIO buffers \(elapsed)s after engine start — input IO never serviced. " +
                        "Most likely VPIO DSP fault (board-ID/downlink) OR the duplex output isn't cycling. " +
                        "Check the engine-build log above; consider useVoiceProcessingMic=false fallback."
                )
            } else {
                Log.mic.err(
                    "WATCHDOG: VPIO mic STALLED after \(snap.buffersReceived) buffers — none in last " +
                        "\(Self.heartbeatInterval)s."
                )
            }
            Log.mic.err("WATCHDOG input state: \(CoreAudioHelpers.inputDiagnosticsSnapshot())")
        }

        if snap.buffersReceived > 0, snap.framesWritten == 0, !writeStallReported {
            writeStallReported = true
            Log.mic.err(
                "WATCHDOG: \(snap.buffersReceived) VPIO buffers received but 0 frames written — " +
                    "ch0-extract / convert / write failing for this format (\(snap.lastSourceFormat))."
            )
        }
    }

    // MARK: - Stats helpers

    @discardableResult
    private func mutateStats<T>(_ body: (inout Stats) -> T) -> T {
        statsLock.lock(); defer { statsLock.unlock() }
        return body(&stats)
    }

    private func snapshotStats() -> Stats {
        statsLock.lock(); defer { statsLock.unlock() }
        return stats
    }

    private func setNotCapturing() {
        lock.lock(); _isCapturing = false; lock.unlock()
    }

    // MARK: - Config-change observer

    private func installConfigChangeObserver() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] _ in self?.handleConfigurationChange() }
    }

    private func removeConfigChangeObserver() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    // MARK: - File handle

    private func setExtFile(_ file: ExtAudioFileRef?) {
        fileLock.lock(); extFile = file; fileLock.unlock()
    }

    private func closeExtFile() {
        fileLock.lock()
        let file = extFile
        extFile = nil
        fileLock.unlock()
        if let file { ExtAudioFileDispose(file) }
    }

    private func currentExtFile() -> ExtAudioFileRef? {
        fileLock.lock(); defer { fileLock.unlock() }
        return extFile
    }
}
