---
status: complete
---

# Component: MeetingDetection

## Purpose and Scope

MeetingDetection decides when a meeting starts and stops based on system audio activity, and emits
`DetectionEvent`s that AppCore consumes. It is a pure decision layer: it reads audio-process
snapshots (from AudioCapture's `AudioActivityMonitor`), applies the validated "in a call" heuristic
(input AND output running for a watchlist app/helper), maps helper processes to user-facing apps via
`MeetingCatalog`, de-bounces transitions, and produces a clean started/stopped event stream.

**In scope:** the in-call state machine per tracked app, helper-process resolution, de-bounce /
hysteresis, the `events()` AsyncStream, the `ActivitySource` seam.

**Out of scope:**
- Raw audio monitoring (owned by `AudioCapture`).
- Calendar-driven detection (owned by `CalendarService` / `AppCore`).
- Notification presentation (owned by `Notifications`).
- Recording lifecycle (owned by `Recording` / `AppCore`).
- De-dup of ad-hoc vs. calendar-driven detection (owned by `AppCore`).

---

## Public Interface

The surface below is **fixed** by `architecture.md` section 6. Signatures are reproduced verbatim;
this doc designs the internals behind them.

```swift
// MARK: - Value types

public enum DetectionEvent: Sendable, Equatable {
    case started(app: DetectedApp)
    case stopped(app: DetectedApp)
}

public struct DetectedApp: Sendable, Equatable {
    public let bundleID: String      // the user-facing app's bundle ID (after helper resolution)
    public let displayName: String   // human-readable name from MeetingCatalog
}

// MARK: - ActivitySource seam (wraps AudioCapture.AudioActivityMonitor)

public protocol ActivitySource: Sendable {
    func activityStream() -> AsyncStream<[AudioProcess]>
}

// MARK: - MeetingDetector

@MainActor @Observable
public final class MeetingDetector {
    public init(catalog: any MeetingCatalog, source: any ActivitySource = LiveActivitySource())
    public func events() -> AsyncStream<DetectionEvent>
    public func start()
    public func stop()
}
```

### `LiveActivitySource`

A thin adapter wrapping `AudioActivityMonitor.live()`:

```swift
public struct LiveActivitySource: ActivitySource {
    public init()
    public func activityStream() -> AsyncStream<[AudioProcess]> {
        // Delegates to AudioActivityMonitor.live().activityStream().
        // The monitor is created once and retained for the lifetime of the struct.
    }
}
```

`AudioActivityMonitor` is an `actor`, so `LiveActivitySource` must `await` the call to
`activityStream()`. Internally the adapter spawns a bridging task that relays elements into the
returned `AsyncStream`. This is strictly plumbing; all logic lives in `MeetingDetector`.

---

## Internal Design Approach

### Data flow

```
AudioActivityMonitor ──[AudioProcess]──► ActivitySource seam
                                              │
                                              ▼
                                      MeetingDetector
                                        ├── WatchlistFilter (MeetingCatalog.isMeetingApp)
                                        ├── HelperResolver  (MeetingCatalog.displayName → parent app)
                                        ├── PerAppStateMachine (one per resolved app)
                                        └── Debouncer (hysteresis window)
                                              │
                                              ▼
                                   AsyncStream<DetectionEvent>  ──► AppCore
```

### 1. Snapshot processing pipeline

On each `[AudioProcess]` snapshot from the activity source:

1. **Filter to watchlist.** For each process, ask `catalog.isMeetingApp(bundleID:)`. Discard
   non-watchlist processes. (The catalog knows both user-facing app IDs and helper IDs.)
2. **Resolve helpers to parent apps.** Group the surviving processes by their resolved user-facing
   app identity. Resolution uses `catalog.displayName(forBundleID:)` plus a hardcoded
   helper-to-parent mapping table inside `MeetingCatalog`:

   | Helper bundle ID | Resolved parent | Display name |
   |---|---|---|
   | `com.apple.WebKit.GPU` | `com.apple.Safari` (or detected browser) | "Safari" |
   | `com.apple.avconferenced` | `com.apple.FaceTime` | "FaceTime" |
   | `com.tinyspeck.slackmacgap.helper` | `com.tinyspeck.slackmacgap` | "Slack" |

   The resolution produces a `(parentBundleID, displayName)` pair. If a parent app and its helper
   are both present, their running flags are OR-merged (if either reports input+output, the parent is
   "in a call").

   **Browser coarseness.** `com.apple.WebKit.GPU` covers all Safari audio (all tabs). Chrome's
   helper processes are similarly coarse. The detector cannot distinguish a meeting tab from a YouTube
   tab. This is an accepted V1 limitation documented in the research. The result is a possible false
   positive (user ignores the notification; nothing auto-records per C2).

3. **Compute per-app "in a call" boolean.** For each resolved parent app, the heuristic is:
   `isInCall = isRunningInput AND isRunningOutput`. This is the validated signal from R1 section 3:
   a process using both mic and speaker is very likely in a call. Output-only (e.g. playing music in
   Slack) or input-only (e.g. voice memo) does not trigger detection. Muted calls still report
   `isRunningInput = true` (the IO registration persists; see R1 caveat).

4. **Feed per-app state machines** (next section).

### 2. Per-app state machine

Each resolved parent app gets an `AppCallState` instance, keyed by `parentBundleID`. The state
machine has three states:

```
         isInCall=true
  idle ────────────────► pendingStarted
   ▲                         │
   │                         │ debounce elapsed
   │                         ▼
   │  debounce elapsed   active
   │◄──── pendingStop ◄──────┘
              ▲          isInCall=false
              │
              │ (isInCall=true while pendingStop → cancel stop, return to active)
```

```swift
enum CallPhase {
    case idle
    case pendingStarted(since: ContinuousClock.Instant)   // debounce before emitting .started
    case active                                            // in-call; .started emitted
    case pendingStop(since: ContinuousClock.Instant)       // debounce before emitting .stopped
}

struct AppCallState {
    let parentBundleID: String
    let displayName: String
    var phase: CallPhase = .idle
}
```

**Transitions (evaluated on each snapshot):**

| Current phase | `isInCall` on this snapshot | Action |
|---|---|---|
| `idle` | `true` | Transition to `pendingStarted(now)`. |
| `idle` | `false` | No-op. |
| `pendingStarted` | `true` and debounce elapsed (>= `startDebounce`) | Emit `.started(app:)`. Transition to `active`. |
| `pendingStarted` | `true` and debounce not elapsed | No-op (wait). |
| `pendingStarted` | `false` | Transition back to `idle` (flap suppressed). |
| `active` | `true` | No-op. |
| `active` | `false` | Transition to `pendingStop(now)`. |
| `pendingStop` | `false` and debounce elapsed (>= `stopDebounce`) | Emit `.stopped(app:)`. Transition to `idle`. Remove entry. |
| `pendingStop` | `false` and debounce not elapsed | No-op (wait). |
| `pendingStop` | `true` | Cancel stop; transition back to `active`. |

**Debounce values (tunable constants, not part of the public API):**

| Parameter | Default | Rationale |
|---|---|---|
| `startDebounce` | 3 seconds | Avoid firing on brief mic-test / accidental IO (e.g. a browser tab autoplaying with mic still open from a previous grant). Long enough to suppress noise, short enough that a real call is detected within seconds of joining. |
| `stopDebounce` | 8 seconds | Calls sometimes drop IO briefly during network blips, renegotiation, or when the user mutes+unmutes system audio. 8 s absorbs these without a premature "meeting ended" event. The auto-stop countdown in AppCore adds another 15 s on top, so the user has 23 s total from IO cessation to auto-stop. |

### 3. OS callback limitation and polling-free design

The validated research (Phase 9 finding, Test 8) established that:

- `kAudioProcessPropertyIsRunningInput` / `kAudioProcessPropertyIsRunningOutput` **do not** post
  listener notifications on macOS.
- `kAudioProcessPropertyIsRunning` (= input OR output) **does** fire, but only on the overall
  no-IO to IO transition (or IO to no-IO). A process already running output that then starts input
  does **not** cause a callback.

This means: the activity stream fires when a process **first** appears in the audio system (IO
starts) and when it **fully** leaves (IO stops), but not on mid-call input-only changes. Since the
in-call heuristic requires input AND output, the detector cannot observe the transition from
"output-only" to "input+output" via a push event alone.

**Practical impact is small.** In a real meeting, the conferencing app registers both input and
output at call-join time (the app opens the mic and speaker together). The "output first, input
later" pattern is uncommon. FaceTime's `avconferenced` was observed to activate output first and
input slightly later, but the process-list change (avconferenced appearing) triggers a re-snapshot
that picks up both flags. The debounce window further absorbs any sequencing delay.

**Design decision:** rely on the push-based `ActivitySource` stream (no polling). The
`AudioActivityMonitor` already re-snapshots `currentProcesses()` on every `kAudioProcessPropertyIsRunning`
callback, reading both `isRunningInput` and `isRunningOutput` fresh. If a mid-call input
start/stop is truly missed (because the overall running boolean did not toggle), the detector will
catch it on the next unrelated process-list change or the next `isRunning` toggle from any tracked
process. A manual "Refresh" is not needed for V1. If real-world testing reveals missed detections,
a low-frequency poll (e.g. every 30 s) can be added inside `ActivitySource` as a fallback without
changing the detector's API.

### 4. `events()` AsyncStream design

```swift
@MainActor @Observable
public final class MeetingDetector {
    private let catalog: any MeetingCatalog
    private let source: any ActivitySource
    private var observeTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<DetectionEvent>.Continuation?
    private var appStates: [String: AppCallState] = [:]  // keyed by parentBundleID

    // Debounce constants
    private let startDebounce: Duration = .seconds(3)
    private let stopDebounce: Duration = .seconds(8)
}
```

**Buffering policy:** `events()` returns a single `AsyncStream<DetectionEvent>` with
`.bufferingPolicy(.unbounded)`. Events are low-frequency (a few per hour at most), so unbounded
buffering is safe and avoids dropping events if the consumer briefly pauses iteration.

**Single consumer model.** The architecture has one consumer: `AppCore`. `MeetingDetector` holds
one continuation. Calling `events()` a second time replaces the previous continuation (the old one
is finished). This keeps the API simple; multi-consumer is unnecessary and would complicate the
state machine (which events has each consumer seen?). If multiple consumers are ever needed, AppCore
can fan-out internally.

**`start()` / `stop()` lifecycle:**

```swift
public func start() {
    guard observeTask == nil else { return }
    observeTask = Task { [weak self] in
        guard let self else { return }
        let stream = await source.activityStream()
        for await snapshot in stream {
            guard !Task.isCancelled else { break }
            self.processSnapshot(snapshot)
        }
    }
}

public func stop() {
    observeTask?.cancel()
    observeTask = nil
    // Emit .stopped for any app currently in active/pendingStop, then clear state.
    for (_, state) in appStates where state.phase == .active || state.phase.isPendingStop {
        eventContinuation?.yield(.stopped(app: DetectedApp(
            bundleID: state.parentBundleID, displayName: state.displayName
        )))
    }
    appStates.removeAll()
    eventContinuation?.finish()
    eventContinuation = nil
}
```

**Debounce tick evaluation.** Because the activity stream is event-driven (not polled), debounce
deadlines may expire between events. Two options:

1. **Evaluate on next snapshot** — when the next activity-stream element arrives, check all pending
   states and emit if their debounce has elapsed. This delays the event emission until the next
   push, which could be seconds or minutes.
2. **Schedule a timer per pending state** — when entering `pendingStarted` or `pendingStop`, schedule
   a `Task.sleep(for: debounce)` that, on wake, re-evaluates the state and emits if still pending.

**Choice: option 2 (timer per pending state).** Timely emission matters: a 3 s start-debounce
should emit at ~3 s, not whenever the next unrelated audio event happens to arrive. The timer task
is cheap (one `Task.sleep` per pending transition; at most a handful active). Implementation
sketch:

```swift
private func enterPendingStarted(for key: String) {
    appStates[key]?.phase = .pendingStarted(since: .now)
    Task { [weak self] in
        try? await Task.sleep(for: self?.startDebounce ?? .seconds(3))
        guard !Task.isCancelled else { return }
        await MainActor.run { self?.evaluateDebounce(for: key) }
    }
}
```

`evaluateDebounce(for:)` checks whether the app is still in the pending phase and the deadline has
passed; if so, transitions and emits. If the phase has already changed (e.g. the process stopped
before the timer fired), the timer is a no-op.

### 5. Tracking multiple concurrent meeting apps

Each resolved parent app is tracked independently via its own `AppCallState`. Two apps can be in
`active` phase simultaneously (e.g. Zoom and Slack Huddle). Each emits its own `.started` / `.stopped`
pair. AppCore enforces "one recording at a time" — if a second detection arrives while already
recording, AppCore queues a notification rather than starting a second recording. That logic is
entirely AppCore's concern; the detector just reports what it sees.

### 6. Process disappearance

If a watchlist process disappears entirely from the snapshot (app quit, process crash), the next
snapshot will not contain it. The snapshot-processing pipeline treats absence as `isInCall = false`
for that app, which triggers the `active → pendingStop` transition (or `pendingStarted → idle`).
The stop debounce then runs normally. This handles ungraceful exits without special-case code.

---

## Dependencies

| Dependency | Direction | What's used |
|---|---|---|
| `MeetingCatalog` (L0 target) | MeetingDetection **depends on** | `isMeetingApp(bundleID:)`, `displayName(forBundleID:)` — watchlist matching + helper resolution |
| `AudioCapture` (package) | MeetingDetection **depends on** (via `ActivitySource` seam) | `AudioProcess` (value type), `AudioActivityMonitor` (wrapped by `LiveActivitySource`) |
| `AppCore` (L2) | **depends on** MeetingDetection | Consumes `MeetingDetector.events()`, calls `start()` / `stop()` |

No dependency on `Calendar`, `Notifications`, `DataStore`, or `Recording`. MeetingDetection is a
pure signal producer.

---

## Test Plan

All tests use `swift-testing` and run headlessly via `swift test` (no hardware, no Core Audio). The
`ActivitySource` seam is replaced with a `FakeActivitySource` that yields scripted `[AudioProcess]`
snapshots on demand. `MeetingCatalog` is replaced with a `FakeMeetingCatalog` that returns
controlled responses.

```swift
struct FakeActivitySource: ActivitySource {
    let continuation: AsyncStream<[AudioProcess]>.Continuation
    let stream: AsyncStream<[AudioProcess]>
    func activityStream() -> AsyncStream<[AudioProcess]> { stream }
    func emit(_ snapshot: [AudioProcess]) { continuation.yield(snapshot) }
}

struct FakeMeetingCatalog: MeetingCatalog {
    var meetingBundleIDs: Set<String> = []
    var displayNames: [String: String] = [:]
    // ...
}
```

Helper for constructing test `AudioProcess` values:

```swift
extension AudioProcess {
    static func stub(
        bundleID: String,
        isRunningInput: Bool = false,
        isRunningOutput: Bool = false,
        pid: pid_t = 1
    ) -> AudioProcess { ... }
}
```

### Test cases

| Test name | What it verifies |
|---|---|
| `emitsStartedWhenWatchlistAppRunsInputAndOutput` | A watchlist app with both `isRunningInput` and `isRunningOutput` true triggers `.started` after the start debounce elapses. Confirms the core heuristic. |
| `outputOnlyDoesNotTriggerInCall` | A watchlist app with only `isRunningOutput = true` (playing audio, no mic) does not emit `.started`. Verifies the "input AND output" requirement. |
| `inputOnlyDoesNotTriggerInCall` | A watchlist app with only `isRunningInput = true` (mic open, no speaker) does not emit `.started`. |
| `noEventForNonWatchlistApp` | A process whose `bundleID` is not in the catalog's watchlist produces no events, even if it has input+output running. |
| `helperProcessMapsToParentApp` | `com.apple.WebKit.GPU` with input+output running emits `.started(app:)` with `bundleID = "com.apple.Safari"` and `displayName = "Safari"`. Confirms helper-to-parent resolution through the catalog. |
| `avconferencedMapsToFaceTime` | `com.apple.avconferenced` with input+output emits `.started` with FaceTime identity. |
| `slackHelperMapsToSlack` | `com.tinyspeck.slackmacgap.helper` with input+output emits `.started` with Slack identity. |
| `debounceSuppressesFlapping` | App goes input+output for 1 s, then drops input, then goes input+output again within the start debounce window. Only one `.started` is emitted (the flap does not produce started-stopped-started). |
| `startDebounceResetOnDropout` | App goes input+output, then drops to idle before the start debounce elapses. No `.started` is emitted. Verifies that a brief audio blip does not trigger detection. |
| `emitsStoppedWhenAudioCeases` | A detected meeting (`.started` emitted) stops running input+output. After the stop debounce, `.stopped` is emitted. |
| `stopDebounceCancelsOnResume` | A detected meeting drops IO briefly (enters `pendingStop`), then IO resumes before the stop debounce elapses. No `.stopped` is emitted; the meeting remains active. |
| `concurrentMeetingAppsTrackedIndependently` | Two different watchlist apps go in-call simultaneously. Each emits its own `.started`. Stopping one emits `.stopped` for that app only; the other remains active. |
| `processDisappearanceTriggersStop` | A watchlist app that was in-call disappears from the process snapshot entirely (app quit). After the stop debounce, `.stopped` is emitted. |
| `stopOnDetectorStop` | Calling `detector.stop()` while an app is in the `active` phase emits `.stopped` for that app and finishes the event stream. |
| `duplicateStartNotEmitted` | An already-active app continues to appear with input+output in successive snapshots. Only one `.started` is emitted (no repeated events). |
| `multipleHelpersSameParentMerged` | Both `com.apple.FaceTime` and `com.apple.avconferenced` appear in the same snapshot. They resolve to the same parent; only one `.started` is emitted for FaceTime, and the OR-merge of their running flags is used. |
| `eventsStreamReplacesOnSecondCall` | Calling `events()` twice finishes the first stream and returns a new one. Events flow only to the second consumer. |
| `nilBundleIDIgnored` | A process with `bundleID = nil` is silently ignored (no crash, no event). |

### What each test does NOT cover (and why)

- **Real Core Audio callbacks** — these are integration/hardware tests, not unit tests. The
  `LiveProcessActivitySource` + `AudioActivityMonitor` are tested separately in `AudioCapture`
  package tests and validated manually (Phase 4.5 / manual-test-app).
- **AppCore de-dup / notification routing** — tested in `AppCore` tests with a fake
  `MeetingDetector` (the detector has no knowledge of calendar events or notifications).
- **Timer precision** — debounce timers use `Task.sleep` which is not guaranteed to wake at the
  exact deadline. Tests use `FakeClock` or advance time explicitly (e.g. emit a snapshot, advance
  past the debounce, emit another snapshot) rather than relying on real-time sleeps. This keeps
  tests deterministic and fast.

### Clock seam for deterministic debounce tests

To avoid real `Task.sleep` in tests, the debounce evaluation should be drivable by a clock seam.
Two options:

1. Inject a `Clock` (Swift `ContinuousClock` protocol) and use `clock.sleep(for:)` in the timer
   tasks. Tests inject an `ImmediateTestClock` or manual-advance clock.
2. Evaluate debounce purely on snapshot arrival: record the `ContinuousClock.Instant` when entering
   a pending state, and on the next snapshot check if `now - since >= debounce`. Tests control
   "now" by injecting a clock or by emitting snapshots with known delays.

**Choice: option 1 (injected clock).** This supports the timer-per-pending design and keeps tests
fully deterministic. The clock is an internal dependency (not exposed in the public API):

```swift
// Internal init for tests
init(catalog: any MeetingCatalog, source: any ActivitySource, clock: any Clock<Duration>)

// Public init uses ContinuousClock
public convenience init(catalog: any MeetingCatalog, source: any ActivitySource) {
    self.init(catalog: catalog, source: source, clock: ContinuousClock())
}
```

---

## Contract Gaps and Risks

1. **`ActivitySource` is synchronous but `AudioActivityMonitor.activityStream()` is async.**
   The `ActivitySource` protocol declares `func activityStream() -> AsyncStream<[AudioProcess]>`,
   a non-async method. But `AudioActivityMonitor` is an `actor`, so calling its
   `activityStream()` requires `await`. `LiveActivitySource` must bridge this — it can create the
   monitor eagerly (in `init`) and relay elements via a spawned task, or it can make the first
   `activityStream()` call block on a `Task` that awaits the actor. Either way, this is
   implementable within the current protocol shape. **Not a blocker, but the bridge task must be
   careful about cancellation and the monitor's lifetime.**

2. **Helper-to-parent mapping lives in `MeetingCatalog`, not `MeetingDetection`.**
   The architecture places `MeetingCatalog` as a shared L0 target. The current
   `MeetingCatalog` protocol has `displayName(forBundleID:)` and `isMeetingApp(bundleID:)` but
   does **not** have an explicit `parentBundleID(forHelper:)` method. The detector needs to
   resolve e.g. `com.apple.WebKit.GPU` to `com.apple.Safari`. Two options: (a) add a
   `parentBundleID(forHelperBundleID:) -> String?` method to `MeetingCatalog`, or (b) encode the
   mapping inside `displayName` + `isMeetingApp` (treat helpers as meeting apps whose display name
   is the parent's, and whose canonical bundleID for dedup is the parent's). **Recommendation: add
   `parentBundleID(forHelperBundleID:)` to the `MeetingCatalog` protocol.** It is a small,
   non-breaking addition that makes the resolution explicit.

3. **`DetectedApp.bundleID` semantics for helpers.** When a helper process triggers detection,
   `DetectedApp.bundleID` should be the **parent** app's bundle ID (e.g. `com.apple.Safari`, not
   `com.apple.WebKit.GPU`), because downstream consumers (AppCore, notifications) use it to
   identify the app. The architecture doc says "the user-facing app" but does not explicitly state
   this convention. **This doc fixes the convention: `DetectedApp.bundleID` is always the resolved
   parent bundle ID.** Flag for architecture doc update.

4. **Browser ambiguity.** `com.apple.WebKit.GPU` resolves to Safari, but Chrome-based meetings
   resolve to Chrome. If a user has a Google Meet tab in Safari and a Zoom tab in Chrome, both
   are detected as separate apps (Safari and Chrome). There is no way to distinguish "meeting tab"
   from "YouTube tab" within either browser. This is documented and accepted (false positives are
   harmless per C2).

5. **OS callback granularity.** Per the research, `kAudioProcessPropertyIsRunning` only fires on
   the overall no-IO to IO (or IO to no-IO) transition. A process that is already playing audio
   and then opens the mic mid-session may not trigger a callback. The risk is a **missed
   detection** for apps that open output before input (e.g. a ringing/notification sound before
   the user answers and mic opens). In practice, the process-list-change callback that fires when
   a new helper appears (e.g. `avconferenced` for FaceTime) triggers a re-snapshot that picks up
   both flags. **Risk: low but non-zero.** The fallback poll (section 3 above) is the mitigation
   if real-world testing surfaces this.
