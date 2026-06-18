import AVFoundation
import Foundation
import os
import QuartzCore
import Synchronization

private let logger = Logger(subsystem: "net.scosman.biscotti.audiocapture", category: "AudioRecorder")

/// Two-stream audio recorder composing a system-audio engine and a mic engine.
///
/// Track alignment: the mic engine fires once with its first-buffer
/// host-clock anchor (the recording's t=0). The system engine starts only
/// after this anchor is known and prepends leading silence equal to the gap
/// between its own first frame and the mic anchor. Both clocks are the same
/// mach host clock, so the gap is precise. A timeout (~3 s) prevents a
/// hung mic from blocking start indefinitely.
///
/// Each stream writes ADTS AAC directly during capture via `ExtAudioFile` —
/// no post-recording encode step. Route-change events are handled by
/// reconnecting the affected engine without tearing down the session.
public actor AudioRecorder {
    // MARK: - Dependencies (injected via seams)

    private let systemEngine: any CaptureEngine
    private let micEngine: any CaptureEngine
    private let deviceChangeProvider: any DeviceChangeProvider
    private let permissionChecker: any SystemPermissionChecker
    private let micPermissionChecker: any MicPermissionChecker
    private let encoder: EncoderSettings

    // MARK: - Session state

    private var paths: CapturePaths?
    private var _startTimestamp: Double = 0

    /// Single-use lifecycle: `idle → recording → finished`. A recorder
    /// records exactly once — after `stop()` it is `finished` and `start()`
    /// throws `CaptureError.recorderConsumed`. Reuse across recordings is
    /// unsupported (the capture engines were validated single-use and hoist
    /// per-session state), so it is rejected here rather than left as a
    /// latent real-time-thread teardown hazard. A *failed* start does not
    /// consume the recorder: it stays `idle` and may be retried.
    private enum Lifecycle {
        case idle
        case recording
        case finished
    }

    private var lifecycle: Lifecycle = .idle
    private var isRecording: Bool {
        lifecycle == .recording
    }

    private var stateTimer: Task<Void, Never>?
    private var routeChangeTask: Task<Void, Never>?
    private var stateContinuations: [UUID: AsyncStream<CaptureState>.Continuation] = [:]

    /// Timeout for waiting on the mic engine's first buffer before
    /// proceeding to start the system engine (seconds). Prevents a
    /// VPIO DSP fault from hanging start() indefinitely.
    static let micFirstBufferTimeout: Duration = .seconds(3)

    /// Maximum number of retry attempts for system engine start failures.
    /// The system engine (Core Audio process tap) can fail intermittently
    /// when the audio HAL is mid-reconfiguration (e.g. VPIO just reclocked
    /// the output device). A short retry with a settle delay resolves most
    /// transient failures.
    ///
    /// 2 retries (3 total attempts) balances resilience against start-time
    /// latency (~500ms worst case). The HAL device-graph reconfiguration on
    /// Apple Silicon typically settles within 100-300ms.
    static let systemStartMaxRetries = 2

    /// Delay between system engine start retries. 250ms matches the observed
    /// HAL settle time on Apple Silicon after VPIO reclocks the output device.
    static let systemStartRetryDelay: Duration = .milliseconds(250)

    /// Maximum number of retry attempts for system engine reconnect failures
    /// during route changes. Same rationale as `systemStartMaxRetries`.
    static let systemReconnectMaxRetries = 2

    /// Delay between system engine reconnect retries. Slightly longer than
    /// start retries because the reconnect path already includes its own
    /// 200ms settle delay inside the engine, so this is additive back-off.
    static let systemReconnectRetryDelay: Duration = .milliseconds(300)

    // MARK: - Init

    /// Creates a recorder with injected capture engines and seams.
    ///
    /// For production use, prefer `AudioRecorder.live(encoder:)` which
    /// wires the real Core Audio / AVAudioEngine implementations.
    public init(
        systemEngine: some CaptureEngine,
        micEngine: some CaptureEngine,
        deviceChangeProvider: some DeviceChangeProvider,
        permissionChecker: some SystemPermissionChecker,
        micPermissionChecker: some MicPermissionChecker,
        encoder: EncoderSettings = .voice
    ) {
        self.systemEngine = systemEngine
        self.micEngine = micEngine
        self.deviceChangeProvider = deviceChangeProvider
        self.permissionChecker = permissionChecker
        self.micPermissionChecker = micPermissionChecker
        self.encoder = encoder
    }

    // MARK: - Permissions

    /// Surfaces both TCC permission prompts (microphone + system audio) **without**
    /// running the recording pipeline.
    ///
    /// The microphone prompt comes from the real authorization API. System-audio
    /// capture has **no** permission API — the prompt only appears when a Core Audio
    /// process tap is created — so it's surfaced by briefly starting and stopping the
    /// *system* engine alone. The microphone `AVAudioEngine`/AAC encoder is never
    /// touched here, so this can't fail for capture-pipeline reasons.
    ///
    /// - Parameter systemProbePath: scratch file the system engine writes during the
    ///   brief probe (safe to discard; a real recording overwrites the real paths).
    /// - Returns: whether microphone access is authorized.
    @discardableResult
    public func requestPermissions(systemProbePath: URL) async -> Bool {
        // Microphone: real authorization API → dialog only when not yet determined.
        let micGranted: Bool = switch micPermissionChecker.authorizationStatus() {
        case .authorized:
            true
        case .notDetermined:
            await micPermissionChecker.requestAccess()
        default:
            false
        }

        // System audio: no API — creating the process tap triggers the prompt.
        // Start + stop ONLY the system engine; never the mic engine.
        do {
            try await systemEngine.start(writingTo: systemProbePath)
            await systemEngine.stop()
        } catch {
            logger.error("System-audio permission probe failed: \(error.localizedDescription, privacy: .public)")
        }

        return micGranted
    }

    // MARK: - Start / Stop

    /// Starts both capture streams against caller-provided paths.
    ///
    /// Checks mic permission before starting engines. Throws
    /// `CaptureError.micPermissionDenied` if the mic is denied or restricted.
    ///
    /// The mic engine starts first so its output-device reclock completes
    /// before the system engine queries the device rate. The system engine
    /// is gated on the mic's first delivered buffer (with a timeout) so:
    ///   1. The mic input IO is confirmed live before the system aggregate
    ///      is created (avoids starving the mic cold-start).
    ///   2. The mic's first-sample host-clock anchor is known, enabling
    ///      precise two-track alignment via leading silence.
    ///
    /// If the system engine fails after the mic started, the mic engine is
    /// stopped before re-throwing.
    public func start(paths: CapturePaths) async throws {
        switch lifecycle {
        case .recording:
            return // already recording — idempotent no-op
        case .finished:
            throw CaptureError.recorderConsumed // single-use: spent
        case .idle:
            break
        }

        // Mic permission preflight.
        let micStatus = micPermissionChecker.authorizationStatus()
        switch micStatus {
        case .authorized:
            break
        case .notDetermined:
            let granted = await micPermissionChecker.requestAccess()
            guard granted else {
                throw CaptureError.micPermissionDenied
            }
        default:
            throw CaptureError.micPermissionDenied
        }

        _lastSystemWriteError = nil

        // Start mic first: VPIO reclocks the output device to the input
        // sample rate. The system tap must query the device after this
        // completes so its ExtAudioFile client format matches the final rate.
        //
        // Wire the first-buffer callback BEFORE start so it's ready when
        // the real-time tap delivers the first buffer (which can happen
        // during or immediately after engine start). For fakes, the
        // callback fires synchronously inside start().
        let micAnchor = try await startMicAndWaitForAnchor(path: paths.micAAC)

        // Forward the mic anchor to the system engine for alignment.
        systemEngine.setMicAnchor(micAnchor)

        // Start system audio with retry. The system engine (Core Audio process
        // tap + aggregate device) can fail intermittently when the HAL is
        // mid-reconfiguration (e.g. VPIO just reclocked the output device).
        // A short retry with a settle delay resolves most transient failures.
        // On exhausted retries, tear down the mic engine.
        do {
            try await startSystemEngineWithRetry(path: paths.systemAAC)
        } catch {
            await micEngine.stop()
            throw error
        }

        // Both started -- stamp the shared reference time.
        let timestamp = CACurrentMediaTime()
        _startTimestamp = timestamp
        self.paths = paths
        lifecycle = .recording

        logger.info("Capture started, timestamp=\(timestamp)")
        emitState()
        startStateTimer()
        startRouteChangeListener()
    }

    /// Starts the mic engine, then waits for its `onFirstBuffer` signal
    /// with a bounded timeout. Returns the host-clock anchor (seconds),
    /// or 0 if the timeout expires (alignment simply degrades to "both
    /// start ~now"). On start failure, re-throws.
    private func startMicAndWaitForAnchor(path: URL) async throws -> Double {
        // Create a one-shot async stream: the callback yields the anchor,
        // and we read it (with timeout) after start returns.
        let stream = AsyncStream<Double>.makeStream()

        micEngine.setOnFirstBuffer { anchor in
            stream.continuation.yield(anchor)
            stream.continuation.finish()
        }

        do {
            try await micEngine.start(writingTo: path)
        } catch {
            micEngine.setOnFirstBuffer(nil)
            stream.continuation.finish()
            logger.error("Mic engine start failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        // Wait for the first buffer or timeout. On real hardware the
        // first buffer arrives from the real-time audio thread after
        // start returns; for fakes it fires during start() and the
        // stream already has a value.
        let anchor = await waitForFirstValue(
            from: stream.stream, timeout: Self.micFirstBufferTimeout
        )

        micEngine.setOnFirstBuffer(nil)
        return anchor
    }

    /// Returns the first value from the stream, or 0 if the timeout
    /// expires before any value arrives.
    private func waitForFirstValue(
        from stream: AsyncStream<Double>, timeout: Duration
    ) async -> Double {
        await withTaskGroup(of: Double?.self) { group in
            group.addTask {
                for await value in stream {
                    return value
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }

            // The first task to finish wins.
            if let result = await group.next(), let anchor = result {
                group.cancelAll()
                return anchor
            }

            // Timeout fired first or stream finished empty.
            group.cancelAll()
            logger.warning(
                "Mic first-buffer timeout (\(timeout)) -- proceeding without alignment anchor"
            )
            return 0
        }
    }

    /// Starts the system engine with retry on transient failures.
    ///
    /// The system engine (Core Audio process tap + aggregate device) can fail
    /// intermittently when the audio HAL is mid-reconfiguration -- typically
    /// right after VPIO reclocked the output device. A short settle delay
    /// between attempts resolves most transient failures.
    private func startSystemEngineWithRetry(path: URL) async throws {
        var lastError: (any Error)?
        for attempt in 0 ... Self.systemStartMaxRetries {
            if attempt > 0 {
                logger.info(
                    "Retrying system engine start (attempt \(attempt + 1, privacy: .public)/\(Self.systemStartMaxRetries + 1, privacy: .public))"
                )
                try await Task.sleep(for: Self.systemStartRetryDelay)
            }
            do {
                try await systemEngine.start(writingTo: path)
                if attempt > 0 {
                    logger.info("System engine start succeeded on retry \(attempt, privacy: .public)")
                }
                return
            } catch {
                lastError = error
                logger.warning(
                    "System engine start failed (attempt \(attempt + 1, privacy: .public)): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        // The loop always runs at least once, so lastError is always set here.
        guard let error = lastError else {
            preconditionFailure("startSystemEngineWithRetry: loop completed without setting lastError")
        }
        logger.error(
            "System engine start failed after \(Self.systemStartMaxRetries + 1, privacy: .public) attempts"
        )
        throw error
    }

    /// Stops capture. Idempotent — safe to call when not recording.
    ///
    /// After stopping, checks the system engine for write errors and
    /// logs them. The error is also available via `lastSystemWriteError`.
    public func stop() async {
        guard lifecycle == .recording else { return }

        lifecycle = .finished
        routeChangeTask?.cancel()
        routeChangeTask = nil
        stateTimer?.cancel()
        stateTimer = nil

        await systemEngine.stop()
        await micEngine.stop()

        // Surface any write errors that occurred during recording.
        if let writeErr = systemEngine.writeError {
            logger.error("System audio write error during recording (OSStatus \(writeErr, privacy: .public))")
            _lastSystemWriteError = writeErr
        }

        logger.info("Capture stopped")
        emitState()
        finishAllContinuations()
    }

    /// Non-nil if the system engine's ExtAudioFile write failed during the
    /// last recording session. Reset on the next `start()`.
    public private(set) var lastSystemWriteError: OSStatus? {
        get { _lastSystemWriteError }
        set { _lastSystemWriteError = newValue }
    }

    private var _lastSystemWriteError: OSStatus?

    // MARK: - State stream

    /// Returns an `AsyncStream` of periodic `CaptureState` snapshots.
    ///
    /// Multiple consumers can call this; each gets its own stream.
    /// The stream finishes when the recorder stops.
    public func stateStream() -> AsyncStream<CaptureState> {
        let id = UUID()
        return AsyncStream { continuation in
            self.stateContinuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                // Use a detached task to avoid holding caller's isolation
                Task { [weak self] in
                    await self?.removeContinuation(id: id)
                }
            }
            // Emit current state immediately
            continuation.yield(self.currentState)
        }
    }

    // MARK: - Internal helpers

    private var currentState: CaptureState {
        let elapsed: TimeInterval = if isRecording, _startTimestamp > 0 {
            CACurrentMediaTime() - _startTimestamp
        } else {
            0
        }
        return CaptureState(
            isRecording: isRecording,
            elapsed: elapsed,
            micLevel: 0, // RMS unwired per phase 9
            systemLevel: 0, // RMS unwired per phase 9
            startTimestamp: _startTimestamp
        )
    }

    private func emitState() {
        let state = currentState
        for (_, continuation) in stateContinuations {
            continuation.yield(state)
        }
    }

    private func finishAllContinuations() {
        for (_, continuation) in stateContinuations {
            continuation.finish()
        }
        stateContinuations.removeAll()
    }

    private func removeContinuation(id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }

    private func startStateTimer() {
        stateTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { break }
                await self?.emitState()
            }
        }
    }
}

// MARK: - Permission inference & tone probe

public extension AudioRecorder {
    /// Returns `true` if the system audio buffers in the first ~2 s were
    /// all-zero, indicating a probable missing screen-recording permission.
    ///
    /// The library reports; it does not own TCC prompts.
    func probableSystemAudioDenied() async -> Bool {
        await permissionChecker.probableDenied()
    }

    /// Returns `true` if any non-zero system audio sample has been observed.
    ///
    /// Used by the tone-probe to detect permission approval as early as
    /// possible (no 2 s wait). Wraps the checker's instantaneous flag.
    func observedSystemAudio() -> Bool {
        permissionChecker.observedNonZero
    }

    /// Default timeout for the system audio tone probe.
    static let defaultProbeTimeout: Duration = .seconds(5)

    /// Poll interval for checking observedSystemAudio during a tone probe.
    internal static let probePollInterval: Duration = .milliseconds(50)

    /// Starts a fresh system tap + plays the probe tone; returns `true` as
    /// soon as non-zero system audio is observed, `false` after `timeout`.
    /// Always tears down the tap and tone before returning.
    ///
    /// Each call creates a fresh tap so a Retry after a first-time grant
    /// works (a pre-grant tap may stay silent). Never throws across this
    /// boundary -- probe failures return `false` and are logged `.public`.
    func probeSystemAudioWithTone(
        timeout: Duration = defaultProbeTimeout
    ) async -> Bool {
        // Reset the checker so prior session data doesn't cause a false positive.
        permissionChecker.reset()

        // The system engine requires a write path; the probe discards this file.
        let probePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("biscotti_probe_\(UUID().uuidString).aac")
        let tonePlayer = ProbeTonePlayer()

        // Start the system engine (creates a fresh tap -> TCC prompt on first use).
        do {
            try await systemEngine.start(writingTo: probePath)
        } catch {
            logger.error(
                "Probe: system engine start failed: \(error.localizedDescription, privacy: .public)"
            )
            try? FileManager.default.removeItem(at: probePath)
            return false
        }

        // Start the probe tone.
        do {
            try tonePlayer.start()
        } catch {
            logger.error(
                "Probe: tone player start failed: \(error.localizedDescription, privacy: .public)"
            )
            await systemEngine.stop()
            try? FileManager.default.removeItem(at: probePath)
            return false
        }

        // Poll for non-zero audio or timeout.
        let observed = await pollForObservedAudio(timeout: timeout)

        // ALWAYS tear down: tone first (so the last tap buffers are silence),
        // then engine.
        tonePlayer.stop()
        await systemEngine.stop()
        try? FileManager.default.removeItem(at: probePath)

        logger.info(
            "Probe complete: observed=\(observed, privacy: .public)"
        )
        return observed
    }

    /// Polls `observedSystemAudio()` at short intervals until `true` or timeout.
    private func pollForObservedAudio(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if observedSystemAudio() {
                return true
            }
            do {
                try await Task.sleep(for: Self.probePollInterval)
            } catch {
                return false // Task cancelled
            }
        }
        return observedSystemAudio() // One final check
    }
}

// MARK: - Route-change handling

extension AudioRecorder {
    private func startRouteChangeListener() {
        routeChangeTask = Task { [weak self] in
            guard let self else { return }
            let stream = deviceChangeProvider.deviceChanges()
            for await event in stream {
                guard !Task.isCancelled else { break }
                await handleDeviceChange(event)
            }
        }
    }

    /// Handles a device-change event by reconnecting the affected engine.
    ///
    /// On OUTPUT change: reconnect the system tap + aggregate device (file-preserving)
    /// with retry on transient failures. The reconnect includes a settle delay
    /// (inside the engine) to let the HAL stabilize.
    /// On INPUT change: the mic engine handles input-route changes internally
    /// via `AVAudioEngineConfigurationChange`, so no action is needed here.
    /// `isRecording` stays `true` throughout -- no audio loss.
    private func handleDeviceChange(_ event: DeviceChangeEvent) async {
        guard isRecording else { return }

        switch event {
        case .outputChanged:
            logger.info("Output device changed -- reconnecting system capture (file-preserving)")
            await reconnectSystemEngineWithRetry()

        case .inputChanged:
            // The mic engine handles input-route changes internally via
            // AVAudioEngineConfigurationChange. No destructive stop/start
            // needed -- the file stays open and audio is preserved.
            logger.info("Input device changed -- mic engine handles internally (file-preserving)")
        }
    }

    /// Reconnects the system engine with retry on transient failures.
    ///
    /// The system engine's `reconnect()` includes its own settle delay to let
    /// the HAL stabilize. On failure, retries up to `systemReconnectMaxRetries`
    /// times with an additional delay between attempts. If all retries are
    /// exhausted, the system track is lost but the mic track continues.
    private func reconnectSystemEngineWithRetry() async {
        var lastError: (any Error)?
        for attempt in 0 ... Self.systemReconnectMaxRetries {
            if attempt > 0 {
                logger.info(
                    "Retrying system engine reconnect (attempt \(attempt + 1, privacy: .public)/\(Self.systemReconnectMaxRetries + 1, privacy: .public))"
                )
                do {
                    try await Task.sleep(for: Self.systemReconnectRetryDelay)
                } catch {
                    return // Task cancelled (recorder stopping)
                }
            }
            do {
                try await systemEngine.reconnect()
                if attempt > 0 {
                    logger.info("System engine reconnect succeeded on retry \(attempt, privacy: .public)")
                }
                return
            } catch {
                lastError = error
                logger.warning(
                    "System engine reconnect failed (attempt \(attempt + 1, privacy: .public)): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        logger.error(
            "System engine reconnect failed after \(Self.systemReconnectMaxRetries + 1, privacy: .public) attempts — system track lost, mic continues: \(lastError?.localizedDescription ?? "unknown", privacy: .public)"
        )
    }
}

// MARK: - Live factory

public extension AudioRecorder {
    /// Creates a recorder wired to real Core Audio / AVAudioEngine backends.
    ///
    /// Use this for production; use the main `init` with fakes for tests.
    static func live(encoder: EncoderSettings = .voice) -> AudioRecorder {
        let permissionChecker = LiveSystemPermissionChecker()
        return AudioRecorder(
            systemEngine: LiveSystemCaptureEngine(permissionChecker: permissionChecker, encoder: encoder),
            micEngine: LiveMicCaptureEngine(encoder: encoder),
            deviceChangeProvider: LiveDeviceChangeProvider(),
            permissionChecker: permissionChecker,
            micPermissionChecker: LiveMicPermissionChecker(),
            encoder: encoder
        )
    }
}
