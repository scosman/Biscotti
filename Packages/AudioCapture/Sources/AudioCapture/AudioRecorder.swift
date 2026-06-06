import Foundation
import os
import QuartzCore

private let logger = Logger(subsystem: "net.scosman.biscotti.audiocapture", category: "AudioRecorder")

/// Two-stream audio recorder composing a system-audio engine and a mic engine.
///
/// Both streams share a single `CACurrentMediaTime()` start reference for
/// alignment. On stop, PCM CAFs are encoded to AAC `.m4a` via
/// `RecordingFileManager`. Route-change events are handled by stopping
/// and restarting the affected engine without tearing down the session.
public actor AudioRecorder {
    // MARK: - Dependencies (injected via seams)

    private let systemEngine: any CaptureEngine
    private let micEngine: any CaptureEngine
    private let deviceChangeProvider: any DeviceChangeProvider
    private let permissionChecker: any SystemPermissionChecker
    private let encoder: EncoderSettings

    // MARK: - Session state

    private var paths: CapturePaths?
    private var _startTimestamp: Double = 0
    private var _isRecording = false
    private var stateTimer: Task<Void, Never>?
    private var routeChangeTask: Task<Void, Never>?
    private var stateContinuations: [UUID: AsyncStream<CaptureState>.Continuation] = [:]

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
        encoder: EncoderSettings = .voiceM4A
    ) {
        self.systemEngine = systemEngine
        self.micEngine = micEngine
        self.deviceChangeProvider = deviceChangeProvider
        self.permissionChecker = permissionChecker
        self.encoder = encoder
    }

    // MARK: - Start / Stop

    /// Starts both capture streams against caller-provided paths.
    ///
    /// Throws on engine setup failure. If the system engine starts but
    /// the mic fails, the system engine is stopped before re-throwing.
    public func start(paths: CapturePaths) async throws {
        guard !_isRecording else { return }

        // Start system audio first (the longer-setup path).
        do {
            try await systemEngine.start(writingTo: paths.systemCAF)
        } catch {
            logger.error("System engine start failed: \(error.localizedDescription)")
            throw error
        }

        // Start mic. On failure, tear down the system engine.
        do {
            try await micEngine.start(writingTo: paths.micCAF)
        } catch {
            logger.error("Mic engine start failed: \(error.localizedDescription)")
            await systemEngine.stop()
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

    /// Stops capture, encodes both CAFs to `.m4a`, and returns an `EncodeResult`.
    ///
    /// Both encodes are attempted independently. On partial failure, the
    /// result contains the succeeded URL(s) alongside the error, so callers
    /// can recover whichever stream succeeded. The original CAFs are always
    /// retained on failure (audio is never lost).
    ///
    /// If called while not recording, returns `nil` (no-op).
    @discardableResult
    public func stop() async throws -> EncodeResult? {
        guard _isRecording, let paths else {
            // Not recording -- nothing to do.
            return nil
        }

        _isRecording = false
        routeChangeTask?.cancel()
        routeChangeTask = nil
        stateTimer?.cancel()
        stateTimer = nil

        await systemEngine.stop()
        await micEngine.stop()

        logger.info("Capture stopped, encoding CAFs to M4A")
        emitState()
        finishAllContinuations()

        // Encode both CAFs independently so a failure in one doesn't
        // prevent the caller from recovering the other.
        var micURL: URL?
        var micError: Error?
        var systemURL: URL?
        var systemError: Error?

        do {
            try RecordingFileManager.encodeToM4A(
                source: paths.micCAF,
                destination: paths.micOutput,
                settings: encoder
            )
            micURL = paths.micOutput
        } catch {
            micError = error
            logger.error("Mic encode failed (CAF retained): \(error.localizedDescription)")
        }

        do {
            try RecordingFileManager.encodeToM4A(
                source: paths.systemCAF,
                destination: paths.systemOutput,
                settings: encoder
            )
            systemURL = paths.systemOutput
        } catch {
            systemError = error
            logger.error("System encode failed (CAF retained): \(error.localizedDescription)")
        }

        let result = EncodeResult(
            mic: micURL,
            system: systemURL,
            micError: micError,
            systemError: systemError
        )

        // If either encode failed, throw so callers who don't inspect
        // the result still learn something went wrong -- but the result
        // is returned alongside the throw via the `partialEncodeFailure` case.
        if let firstError = micError ?? systemError {
            throw CaptureError.partialEncodeFailed(result: result, underlying: firstError)
        }

        return result
    }

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
    static func live(encoder: EncoderSettings = .voiceM4A) -> AudioRecorder {
        let permissionChecker = LiveSystemPermissionChecker()
        return AudioRecorder(
            systemEngine: LiveSystemCaptureEngine(permissionChecker: permissionChecker),
            micEngine: LiveMicCaptureEngine(encoder: encoder),
            deviceChangeProvider: LiveDeviceChangeProvider(),
            permissionChecker: permissionChecker,
            encoder: encoder
        )
    }
}
