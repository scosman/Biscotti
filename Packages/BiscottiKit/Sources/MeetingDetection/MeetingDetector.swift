import AudioCapture
import MeetingCatalog
import Observation
import os

private let logger = Logger(
    subsystem: "net.scosman.biscotti",
    category: "Detection"
)

// MARK: - Per-app state machine types

private enum CallPhase {
    case idle
    case pendingStarted(since: ContinuousClock.Instant)
    case active
    case pendingStop(since: ContinuousClock.Instant)

    var isPendingStop: Bool {
        if case .pendingStop = self { return true }
        return false
    }
}

private struct AppCallState {
    let app: DetectedApp
    var phase: CallPhase = .idle
}

/// Accumulates OR-merged input/output flags across processes sharing a parent.
private struct MergedFlags {
    let app: DetectedApp
    var input: Bool
    var output: Bool

    var isInCall: Bool {
        input && output
    }
}

// MARK: - MeetingDetector

/// Observes audio process activity and emits debounced detection events
/// when meeting apps transition between in-call and idle states.
///
/// Uses the `MeetingCatalog` watchlist to filter relevant apps, resolves
/// helper processes to their parent app, and applies a per-app state
/// machine with configurable debounce to suppress flapping.
@MainActor @Observable
public final class MeetingDetector {
    // MARK: - Dependencies

    private let catalog: any MeetingCatalog
    private let source: any ActivitySource
    private let clock: AnyClock

    // MARK: - State

    private var observeTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<DetectionEvent>.Continuation?
    private var appStates: [String: AppCallState] = [:]
    private var debounceTasks: [String: Task<Void, Never>] = [:]

    /// Whether at least one non-self process was using the mic in the
    /// previous snapshot. Used to detect the >=1 -> 0 transition.
    private var hadNonSelfMicUsers = false

    /// Pending debounce task for the all-mic-users-stopped event.
    /// Cancelled when a non-self mic user reappears before the debounce elapses.
    private var micStopDebounceTask: Task<Void, Never>?

    // MARK: - Debounce constants

    let startDebounce: Duration = .seconds(3)
    let stopDebounce: Duration = .seconds(8)
    let micStopDebounce: Duration = .seconds(5)

    /// The bundle ID prefix of the current app, used to exclude Biscotti's
    /// own mic usage from the "non-self mic users" set. Matches any
    /// bundle ID that starts with this prefix (covers the main app and
    /// helper XPC services like the transcriber).
    private let selfBundlePrefix: String

    // MARK: - Init

    /// Creates a detector with an injected clock for deterministic tests.
    public init(
        catalog: any MeetingCatalog,
        source: any ActivitySource,
        clock: AnyClock,
        selfBundlePrefix: String = "net.scosman.biscotti"
    ) {
        self.catalog = catalog
        self.source = source
        self.clock = clock
        self.selfBundlePrefix = selfBundlePrefix
    }

    /// Creates a detector using `ContinuousClock` and the default live
    /// activity source.
    public convenience init(
        catalog: any MeetingCatalog,
        source: any ActivitySource = LiveActivitySource()
    ) {
        self.init(
            catalog: catalog,
            source: source,
            clock: AnyClock(ContinuousClock())
        )
    }

    // MARK: - Public API

    /// Returns a stream of debounced detection events.
    ///
    /// Calling this a second time finishes the previous stream and returns
    /// a new one. Events flow only to the most recent consumer.
    public func events() -> AsyncStream<DetectionEvent> {
        eventContinuation?.finish()
        eventContinuation = nil

        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            self.eventContinuation = continuation
        }
    }

    /// Begin observing audio process activity.
    public func start() {
        guard observeTask == nil else { return }
        observeTask = Task { [weak self] in
            guard let self else { return }
            let stream = source.activityStream()
            for await snapshot in stream {
                guard !Task.isCancelled else { break }
                processSnapshot(snapshot)
            }
        }
    }

    /// Stop observing. Emits `.stopped` for any active/pending-stop apps
    /// and finishes the event stream.
    public func stop() {
        observeTask?.cancel()
        observeTask = nil

        for task in debounceTasks.values {
            task.cancel()
        }
        debounceTasks.removeAll()

        micStopDebounceTask?.cancel()
        micStopDebounceTask = nil

        for (_, state) in appStates {
            switch state.phase {
            case .active, .pendingStop:
                emit(.stopped(app: state.app))
            case .idle, .pendingStarted:
                break
            }
        }
        appStates.removeAll()
        hadNonSelfMicUsers = false

        eventContinuation?.finish()
        eventContinuation = nil
    }

    // MARK: - Snapshot processing pipeline

    private func processSnapshot(_ snapshot: [AudioProcess]) {
        // Track non-self mic users across ALL processes (not just watchlist).
        // Fires .allMicUsersStopped on the >=1 -> 0 transition.
        updateMicUserTracking(snapshot)

        // Step 1 & 2: Filter to watchlist, resolve helpers, OR-merge
        // raw input/output flags for processes that share a parent.
        var merged: [String: MergedFlags] = [:]

        for process in snapshot {
            guard let bundleID = process.bundleID else { continue }
            guard catalog.isMeetingApp(bundleID: bundleID) else { continue }

            let parentID = catalog.parentBundleID(
                forHelperBundleID: bundleID
            ) ?? bundleID
            let name = catalog.displayName(forBundleID: parentID) ?? parentID

            if var existing = merged[parentID] {
                existing.input = existing.input || process.isRunningInput
                existing.output = existing.output || process.isRunningOutput
                merged[parentID] = existing
            } else {
                let app = DetectedApp(bundleID: parentID, displayName: name)
                merged[parentID] = MergedFlags(
                    app: app,
                    input: process.isRunningInput,
                    output: process.isRunningOutput
                )
            }
        }

        // Step 3: Feed per-app state machines.
        for (parentID, flags) in merged {
            feedStateMachine(
                parentID: parentID,
                app: flags.app,
                isInCall: flags.isInCall
            )
        }

        // Step 4: Handle apps that disappeared from the snapshot.
        let presentParentIDs = Set(merged.keys)
        for parentID in appStates.keys where !presentParentIDs.contains(parentID) {
            guard let state = appStates[parentID] else { continue }
            feedStateMachine(
                parentID: parentID,
                app: state.app,
                isInCall: false
            )
        }
    }

    // MARK: - Non-self mic user tracking

    /// Checks whether any non-Biscotti process is using the mic and
    /// emits `.allMicUsersStopped` after the non-self mic-user set has
    /// been continuously empty for `micStopDebounce` seconds. Cancels
    /// any pending debounce if a non-self mic user reappears.
    private func updateMicUserTracking(_ snapshot: [AudioProcess]) {
        let hasNonSelfMicUsers = snapshot.contains { process in
            guard process.isRunningInput else { return false }
            guard let bundleID = process.bundleID else {
                // Unknown-bundle processes count as non-self
                return true
            }
            return !bundleID.hasPrefix(selfBundlePrefix)
        }

        if hadNonSelfMicUsers, !hasNonSelfMicUsers {
            // Transition to empty -- start debounce timer
            enterMicStopDebounce()
        } else if hasNonSelfMicUsers {
            // A non-self mic user is present -- cancel any pending debounce
            cancelMicStopDebounce()
        }
        hadNonSelfMicUsers = hasNonSelfMicUsers
    }

    private func enterMicStopDebounce() {
        // Cancel any existing debounce (shouldn't normally exist, but
        // guards against double-fire).
        micStopDebounceTask?.cancel()

        let clock = clock
        let debounce = micStopDebounce
        micStopDebounceTask = Task { [weak self] in
            try? await clock.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.resolveMicStopDebounce()
        }
    }

    private func resolveMicStopDebounce() {
        micStopDebounceTask = nil
        emit(.allMicUsersStopped)
        logger.info("All non-self mic users stopped (after debounce)")
    }

    private func cancelMicStopDebounce() {
        micStopDebounceTask?.cancel()
        micStopDebounceTask = nil
    }

    // MARK: - State machine transitions

    private func feedStateMachine(
        parentID: String,
        app: DetectedApp,
        isInCall: Bool
    ) {
        let state = appStates[parentID] ?? AppCallState(app: app)

        switch state.phase {
        case .idle:
            if isInCall {
                enterPendingStarted(parentID: parentID, app: app)
            }

        case .pendingStarted:
            if !isInCall {
                // Flap suppressed: go back to idle
                cancelDebounce(for: parentID)
                appStates.removeValue(forKey: parentID)
                logger.debug("Flap suppressed for \(app.displayName)")
            }
            // If still isInCall, the debounce timer handles the transition

        case .active:
            if !isInCall {
                enterPendingStop(parentID: parentID, app: app)
            }

        case .pendingStop:
            if isInCall {
                // Cancel stop, return to active
                cancelDebounce(for: parentID)
                appStates[parentID]?.phase = .active
                logger.debug(
                    "Stop cancelled for \(app.displayName) — IO resumed"
                )
            }
            // If still !isInCall, the debounce timer handles the transition
        }
    }

    // MARK: - Debounce scheduling

    private func enterPendingStarted(
        parentID: String,
        app: DetectedApp
    ) {
        let now = ContinuousClock.now
        appStates[parentID] = AppCallState(app: app)
        appStates[parentID]?.phase = .pendingStarted(since: now)

        let clock = clock
        let debounce = startDebounce
        debounceTasks[parentID] = Task { [weak self] in
            try? await clock.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.resolveStartDebounce(for: parentID)
        }
    }

    private func resolveStartDebounce(for parentID: String) {
        guard let state = appStates[parentID],
              case .pendingStarted = state.phase
        else { return }

        appStates[parentID]?.phase = .active
        debounceTasks.removeValue(forKey: parentID)
        emit(.started(app: state.app))
        logger.info(
            "Meeting detected: \(state.app.displayName) (\(state.app.bundleID))"
        )
    }

    private func enterPendingStop(
        parentID: String,
        app _: DetectedApp
    ) {
        let now = ContinuousClock.now
        appStates[parentID]?.phase = .pendingStop(since: now)

        let clock = clock
        let debounce = stopDebounce
        debounceTasks[parentID] = Task { [weak self] in
            try? await clock.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.resolveStopDebounce(for: parentID)
        }
    }

    private func resolveStopDebounce(for parentID: String) {
        guard let state = appStates[parentID],
              case .pendingStop = state.phase
        else { return }

        debounceTasks.removeValue(forKey: parentID)
        appStates.removeValue(forKey: parentID)
        emit(.stopped(app: state.app))
        logger.info(
            "Meeting ended: \(state.app.displayName) (\(state.app.bundleID))"
        )
    }

    private func cancelDebounce(for parentID: String) {
        debounceTasks[parentID]?.cancel()
        debounceTasks.removeValue(forKey: parentID)
    }

    // MARK: - Event emission

    private func emit(_ event: DetectionEvent) {
        eventContinuation?.yield(event)
    }
}
