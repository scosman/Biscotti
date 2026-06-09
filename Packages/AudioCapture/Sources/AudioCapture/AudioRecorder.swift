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
    private var _isRecording = false
    private var stateTimer: Task<Void, Never>?
    private var routeChangeTask: Task<Void, Never>?
    private var stateContinuations: [UUID: AsyncStream<CaptureState>.Continuation] = [:]

    /// Timeout for waiting on the mic engine's first buffer before
    /// proceeding to start the system engine (seconds). Prevents a
    /// VPIO DSP fault from hanging start() indefinitely.
    static let micFirstBufferTimeout: Duration = .seconds(3)

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
            logger.error("System-audio permission probe failed: \(error.localizedDescription)")
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
        guard !_isRecording else { return }

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

        // Start system audio. On failure, tear down the mic engine.
        do {
            try await systemEngine.start(writingTo: paths.systemAAC)
        } catch {
            logger.error("System engine start failed: \(error.localizedDescription)")
            await micEngine.stop()
            throw error
        }

        // Both started -- stamp the shared reference time.
        let timestamp = CACurrentMediaTime()
        _startTimestamp = timestamp
        self.paths = paths
        _isRecording = true

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
            logger.error("Mic engine start failed: \(error.localizedDescription)")
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

    /// Stops capture. Idempotent — safe to call when not recording.
    ///
    /// After stopping, checks the system engine for write errors and
    /// logs them. The error is also available via `lastSystemWriteError`.
    public func stop() async {
        guard _isRecording else { return }

        _isRecording = false
        routeChangeTask?.cancel()
        routeChangeTask = nil
        stateTimer?.cancel()
        stateTimer = nil

        await systemEngine.stop()
        await micEngine.stop()

        // Surface any write errors that occurred during recording.
        if let writeErr = systemEngine.writeError {
            logger.error("System audio write error during recording (OSStatus \(writeErr))")
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

    // MARK: - Permission inference

    /// Returns `true` if the system audio buffers in the first ~2 s were
    /// all-zero, indicating a probable missing screen-recording permission.
    ///
    /// The library reports; it does not own TCC prompts.
    public func probableSystemAudioDenied() async -> Bool {
        await permissionChecker.probableDenied()
    }

    // MARK: - Internal helpers

    private var currentState: CaptureState {
        let elapsed: TimeInterval = if _isRecording, _startTimestamp > 0 {
            CACurrentMediaTime() - _startTimestamp
        } else {
            0
        }
        return CaptureState(
            isRecording: _isRecording,
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

    // MARK: - Route-change handling

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
    /// On OUTPUT change: reconnect the system tap + aggregate device (file-preserving).
    /// On INPUT change: the mic engine handles input-route changes internally
    /// via `AVAudioEngineConfigurationChange`, so no action is needed here.
    /// `isRecording` stays `true` throughout -- no audio loss.
    private func handleDeviceChange(_ event: DeviceChangeEvent) async {
        guard _isRecording else { return }

        switch event {
        case .outputChanged:
            logger.info("Output device changed -- reconnecting system capture (file-preserving)")
            do {
                try await systemEngine.reconnect()
            } catch {
                logger.error("System engine reconnect failed after route change: \(error.localizedDescription)")
            }

        case .inputChanged:
            // The mic engine handles input-route changes internally via
            // AVAudioEngineConfigurationChange. No destructive stop/start
            // needed -- the file stays open and audio is preserved.
            logger.info("Input device changed -- mic engine handles internally (file-preserving)")
        }
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
