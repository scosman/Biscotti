---
status: complete
---

# Phase 4: MeetingDetection Module

## Overview

Build the `MeetingDetection` module — a pure signal producer that observes audio process activity
through an `ActivitySource` seam, applies the "input AND output running" heuristic against the
`MeetingCatalog` watchlist, resolves helper processes to parent apps, debounces transitions via a
per-app state machine, and emits a clean `AsyncStream<DetectionEvent>` for AppCore to consume.

This phase creates a new `MeetingDetection` target in BiscottiKit (L1, depends on AudioCapture +
MeetingCatalog) with full unit tests driven entirely by synthetic activity sources — no hardware or
Core Audio required.

## Steps

1. **Create target directories.**
   - `Sources/MeetingDetection/`
   - `Tests/MeetingDetectionTests/`

2. **Add `MeetingDetection` target to `Package.swift`.**
   - New target: `MeetingDetection`, depends on `AudioCapture` (package) + `MeetingCatalog`.
   - New product: `.library(name: "MeetingDetection", targets: ["MeetingDetection"])`.
   - New test target: `MeetingDetectionTests`, depends on `MeetingDetection`, `MeetingCatalog`,
     `AudioCapture`.

3. **Create `DetectionEvent.swift` — public value types.**
   ```swift
   public enum DetectionEvent: Sendable, Equatable {
       case started(app: DetectedApp)
       case stopped(app: DetectedApp)
   }
   public struct DetectedApp: Sendable, Equatable, Hashable {
       public let bundleID: String
       public let displayName: String
   }
   ```

4. **Create `ActivitySource.swift` — the seam protocol.**
   ```swift
   public protocol ActivitySource: Sendable {
       func activityStream() -> AsyncStream<[AudioProcess]>
   }
   ```

5. **Create `LiveActivitySource.swift` — production adapter wrapping `AudioActivityMonitor`.**
   Spawns a bridging task that `await`s the actor's `activityStream()` and relays into a
   synchronously-returned `AsyncStream`.

6. **Create `MeetingDetector.swift` — the core logic.**
   - `@MainActor @Observable public final class MeetingDetector`
   - Internal `CallPhase` enum (idle / pendingStarted / active / pendingStop) with timestamps.
   - Internal `AppCallState` struct keyed by resolved parent bundle ID.
   - `processSnapshot(_:)` pipeline: filter to watchlist, resolve helpers, merge flags for same
     parent, compute `isInCall`, feed per-app state machine transitions.
   - Timer-based debounce: on entering pending states, schedule a `clock.sleep(for:)` task that
     re-evaluates and emits if still pending.
   - Injected clock (`any Clock<Duration>`) for deterministic tests; public init defaults to
     `ContinuousClock`.
   - `events()` returns `AsyncStream<DetectionEvent>` (single consumer, replaces prior).
   - `start()` / `stop()` lifecycle; `stop()` emits `.stopped` for active/pendingStop apps and
     finishes the stream.

7. **Write unit tests in `MeetingDetectionTests.swift`.**
   - `FakeActivitySource`: yields scripted `[AudioProcess]` snapshots.
   - `FakeMeetingCatalog`: returns controlled watchlist/parent/name results.
   - `AudioProcess` test helper via `AudioProcess.init` with known values.
   - Use `ImmediateClock` (a custom test clock that completes `sleep` immediately) so debounce
     timers fire without real delays.
   - Test cases per the component spec test plan (18 cases).

## Tests

- `emitsStartedWhenWatchlistAppRunsInputAndOutput` — core heuristic: input+output triggers `.started` after debounce.
- `outputOnlyDoesNotTriggerInCall` — output-only does not emit.
- `inputOnlyDoesNotTriggerInCall` — input-only does not emit.
- `noEventForNonWatchlistApp` — unknown bundle ID produces no events.
- `helperProcessMapsToParentApp` — WebKit.GPU resolves to Safari.
- `avconferencedMapsToFaceTime` — avconferenced resolves to FaceTime.
- `slackHelperMapsToSlack` — Slack helper resolves to Slack.
- `debounceSuppressesFlapping` — flap within start debounce window emits only one `.started`.
- `startDebounceResetOnDropout` — dropout before start debounce elapsed produces no event.
- `emitsStoppedWhenAudioCeases` — after `.started`, audio stop + stop debounce emits `.stopped`.
- `stopDebounceCancelsOnResume` — IO resumes before stop debounce cancels the stop.
- `concurrentMeetingAppsTrackedIndependently` — two apps emit independent started/stopped pairs.
- `processDisappearanceTriggersStop` — app vanishing from snapshot triggers stop after debounce.
- `stopOnDetectorStop` — calling `stop()` while active emits `.stopped` and finishes stream.
- `duplicateStartNotEmitted` — continued presence of active app does not re-emit `.started`.
- `multipleHelpersSameParentMerged` — FaceTime + avconferenced merge into one detection.
- `eventsStreamReplacesOnSecondCall` — second `events()` call finishes the first stream.
- `nilBundleIDIgnored` — process with nil bundleID causes no crash or event.
