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
    /// Mic came up; waiting for it to stay up for `startDebounce` before
    /// treating this as a real meeting.
    case pendingStart
    /// Meeting confirmed — `.started` has been emitted.
    case active
    /// Mic went down while active; waiting for sustained silence
    /// (`stopDebounce`) before treating the meeting as ended.
    case pendingStop
}

private struct AppCallState {
    let app: DetectedApp
    var phase: CallPhase = .idle
}

/// OR-merges the mic (input) flag across processes sharing a parent app.
///
/// Detection keys on the microphone ONLY. Output is intentionally not a
/// signal: far too many non-meeting apps play audio. A watch-listed app
/// *holding the mic*, persistently, is the meeting signal.
private struct MergedFlags {
    let app: DetectedApp
    var mic: Bool
}

// MARK: - MeetingDetector

/// Observes audio process activity and emits debounced detection events
/// when a watch-listed meeting app starts or stops using the microphone.
///
/// Detection is mic-driven and edge-triggered, with no instantaneous
/// polling: a meeting becomes `.started` once a watch-listed app holds the
/// mic *continuously* for `startDebounce`, and `.stopped` once the mic
/// stays released for `stopDebounce`. Any mic-drop during the start window
/// aborts (so a brief mic probe never notifies); the debounce timers are
/// cancelled on the opposite edge rather than re-sampled at fire time, so
/// the outcome never depends on which instant the timer happens to land on.
///
/// Uses the `MeetingCatalog` watchlist to filter relevant apps and resolves
/// helper processes to their parent app.
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
            case .idle, .pendingStart:
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

        // Step 1 & 2: Filter to watchlist, resolve helpers, OR-merge the
        // mic flag for processes that share a parent.
        var merged: [String: MergedFlags] = [:]

        for process in snapshot {
            guard let bundleID = process.bundleID else { continue }
            guard catalog.isMeetingApp(bundleID: bundleID) else { continue }

            let parentID = catalog.parentBundleID(
                forHelperBundleID: bundleID
            ) ?? bundleID
            let name = catalog.displayName(forBundleID: parentID) ?? parentID

            if var existing = merged[parentID] {
                existing.mic = existing.mic || process.isRunningInput
                merged[parentID] = existing
            } else {
                let app = DetectedApp(bundleID: parentID, displayName: name)
                merged[parentID] = MergedFlags(
                    app: app,
                    mic: process.isRunningInput
                )
            }
        }

        // Step 3: Feed per-app state machines (mic signal only).
        for (parentID, flags) in merged {
            feedStateMachine(parentID: parentID, app: flags.app, mic: flags.mic)
        }

        // Step 4: Handle apps that disappeared from the snapshot.
        let presentParentIDs = Set(merged.keys)
        for parentID in appStates.keys where !presentParentIDs.contains(parentID) {
            guard let state = appStates[parentID] else { continue }
            feedStateMachine(parentID: parentID, app: state.app, mic: false)
        }
    }

    // MARK: - State machine transitions

    private func feedStateMachine(
        parentID: String,
        app: DetectedApp,
        mic: Bool
    ) {
        let state = appStates[parentID] ?? AppCallState(app: app)

        switch state.phase {
        case .idle:
            if mic {
                enterPendingStart(parentID: parentID, app: app)
            }

        case .pendingStart:
            if !mic {
                // Mic dropped before it stayed up for `startDebounce`. Abort
                // back to idle — a meeting requires the mic to come up AND
                // stay up. A later sustained mic starts a fresh window. The
                // timer firing therefore *proves* the mic never dropped, so
                // there is no instantaneous resolve check.
                cancelDebounce(for: parentID)
                appStates.removeValue(forKey: parentID)
                logger.debug(
                    "Start aborted for \(app.displayName) — mic dropped before sustained"
                )
            }

        case .active:
            if !mic {
                enterPendingStop(parentID: parentID, app: app)
            }

        case .pendingStop:
            if mic {
                // Mic returned before sustained silence elapsed — still in
                // the meeting. Cancel the stop and return to active.
                cancelDebounce(for: parentID)
                appStates[parentID]?.phase = .active
                logger.debug(
                    "Stop cancelled for \(app.displayName) — mic resumed"
                )
            }
            // If still no mic, the debounce timer handles the transition.
        }
    }

    // MARK: - Debounce scheduling

    /// Mic came up while idle. Enter `pendingStart` and schedule the
    /// sustained-mic timer. If the mic drops before it fires,
    /// `feedStateMachine` cancels this task and returns to idle, so the
    /// timer only ever fires when the mic stayed up the whole window.
    private func enterPendingStart(parentID: String, app: DetectedApp) {
        var newState = AppCallState(app: app)
        newState.phase = .pendingStart
        appStates[parentID] = newState

        let clock = clock
        let debounce = startDebounce
        debounceTasks[parentID] = Task { [weak self] in
            try? await clock.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.resolveStartDebounce(for: parentID)
        }
    }

    /// The sustained-mic timer fired without being cancelled — i.e. the mic
    /// stayed up for the whole `startDebounce` window — so promote to active
    /// and emit `.started`. No instantaneous flag check: the
    /// cancel-on-mic-drop path guarantees the mic never dropped.
    private func resolveStartDebounce(for parentID: String) {
        guard let state = appStates[parentID],
              case .pendingStart = state.phase
        else { return }

        debounceTasks.removeValue(forKey: parentID)
        appStates[parentID]?.phase = .active
        emit(.started(app: state.app))
        logger.info(
            "Meeting detected: \(state.app.displayName) (\(state.app.bundleID))"
        )
    }

    private func enterPendingStop(parentID: String, app _: DetectedApp) {
        appStates[parentID]?.phase = .pendingStop

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

// MARK: - Non-self mic user tracking

extension MeetingDetector {
    // MARK: - Apple system service denylist

    // Design decision: we use a catalog-driven denylist for Apple system
    // services on the mic-stop path. Any process whose bundleID starts with
    // "com.apple." is IGNORED for mic-user counting UNLESS the catalog
    // recognises it as a meeting app (e.g. FaceTime, avconferenced, Safari,
    // WebKit.GPU).
    //
    // Root cause: com.apple.CoreSpeech (and similar system daemons) holds
    // the mic for voice isolation / Siri / dictation and drops it during
    // Bluetooth device transitions (e.g. AirPods switch). That drop causes
    // a false >=1->0 transition that fires allMicUsersStopped while a real
    // meeting is still active.
    //
    // Alternative considered (Option 1 — symmetric start/stop using catalog
    // only): count only catalog-recognised apps on BOTH the start and stop
    // paths. Rejected because allMicUsersStopped is a secondary safety-net
    // signal for non-catalogued meeting apps — narrowing its scope to
    // catalog-only apps would defeat its purpose. The denylist approach
    // preserves broad non-Apple coverage (any third-party app still counts)
    // while filtering the known-noisy Apple system services.

    /// Returns `true` when the process should be ignored for mic-user
    /// counting: it has an `com.apple.*` bundle ID but is NOT a recognised
    /// meeting app in the catalog. Apple system services like CoreSpeech,
    /// Siri, and dictation use the mic transiently and create false
    /// stop-transitions during Bluetooth device switches.
    private func isIgnoredAppleSystemService(_ bundleID: String) -> Bool {
        bundleID.hasPrefix("com.apple.") && !catalog.isMeetingApp(bundleID: bundleID)
    }

    /// Checks whether any non-Biscotti process is using the mic and
    /// emits `.allMicUsersStopped` after the non-self mic-user set has
    /// been continuously empty for `micStopDebounce` seconds. Cancels
    /// any pending debounce if a non-self mic user reappears.
    private func updateMicUserTracking(_ snapshot: [AudioProcess]) {
        var hasNonSelfMicUsers = false

        for process in snapshot where process.isRunningInput {
            if let bundleID = process.bundleID {
                if bundleID.hasPrefix(selfBundlePrefix) {
                    // Our own process -- excluded from non-self counting.
                    continue
                } else if isIgnoredAppleSystemService(bundleID) {
                    // Apple system service (not a meeting app) -- ignored.
                    continue
                } else {
                    hasNonSelfMicUsers = true
                    break
                }
            } else {
                // nil bundleID -- conservatively counted as non-self.
                hasNonSelfMicUsers = true
                break
            }
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
        // Self-verify: only emit if non-self mic users are still absent.
        // A snapshot arriving between timer-start and resolve may have
        // restored mic users (cancellation is the primary guard, but
        // this is the belt-and-suspenders check).
        guard !hadNonSelfMicUsers else {
            logger.debug(
                "Mic-stop debounce resolved but non-self mic users reappeared -- suppressing"
            )
            return
        }
        emit(.allMicUsersStopped)
        logger.info("All non-self mic users stopped (after debounce)")
    }

    private func cancelMicStopDebounce() {
        micStopDebounceTask?.cancel()
        micStopDebounceTask = nil
    }
}
