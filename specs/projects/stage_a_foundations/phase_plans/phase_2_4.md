---
status: complete
---

# Phase 2.4: Per-Process Monitoring (AudioActivityMonitor)

## Overview

Implement `AudioActivityMonitor`, a push-based actor that emits `AsyncStream<[AudioProcess]>` snapshots whenever the system process list changes or a process's running state toggles. Uses `kAudioProcessPropertyIsRunning` listeners (NOT `IsRunningInput`/`IsRunningOutput`, which don't post notifications on macOS -- see Apple Forums 825780) with IO state re-read on each fire. Per-process listeners are reconciled as processes appear/disappear.

The monitor is built on a testability seam (`ProcessActivitySource` protocol) so all reconciliation, diffing, and stream emission logic can be exercised with synthetic inputs -- no live audio hardware required in tests.

## Design: Testability Seam

### Protocol (`ProcessActivitySource`)

Placed in `CaptureEngine.swift` alongside existing seams. Two responsibilities:

1. **Snapshot**: return current `[AudioProcess]` on demand.
2. **Change stream**: return `AsyncStream<Void>` that fires whenever the process list or any process's running state changes (the monitor re-snapshots on each event).

### Live implementation (`LiveProcessActivitySource`)

Thin Core Audio wrapper in its own file. Registers:
- One `kAudioHardwarePropertyProcessObjectList` system listener (process list changes).
- Per-process `kAudioProcessPropertyIsRunning` listeners, reconciled on each process list change.

All listeners yield into the same `AsyncStream<Void>` continuation. Listeners are removed on stream termination.

### Fake implementation (`FakeProcessActivitySource`)

In `Tests/Fakes/`. Lets tests:
- Set the process list that `currentProcesses()` returns.
- Push synthetic change notifications into the stream.
- Uses `Mutex`/`Atomic` pattern matching `FakeDeviceChangeProvider`.

### `AudioActivityMonitor` actor

Consumes any `ProcessActivitySource`. On each change event, calls `currentProcesses()`, compares to previous snapshot, yields new snapshot if changed. Supports multiple concurrent `activityStream()` consumers via continuation map (same pattern as `AudioRecorder.stateStream()`).

## Steps

### 1. Add `ProcessActivitySource` protocol to `CaptureEngine.swift`

- `func currentProcesses() -> [AudioProcess]`
- `func processChanges() -> AsyncStream<Void>`
- Doc comment explaining Real vs Test usage

### 2. Add listener helpers to `CoreAudioHelpers.swift`

Port from `experiments/AudioLab/Sources/CoreAudioHelpers.swift`:
- `ProcessListListener` struct (block + queue)
- `addProcessListListener(queue:handler:)` / `removeProcessListListener(_:)`
- `ProcessPropertyListener` struct (`@unchecked Sendable`, objectID, selector, block, queue)
- `addProcessPropertyListener(processID:property:queue:handler:)` / `removeProcessPropertyListener(_:)`

### 3. Create `LiveProcessActivitySource.swift`

- Implements `ProcessActivitySource`
- `currentProcesses()` delegates to `CoreAudioHelpers.allAudioProcesses()`
- `processChanges()` returns `AsyncStream<Void>`:
  - Registers system process list listener
  - On each fire: reconcile per-process `kAudioProcessPropertyIsRunning` listeners, then yield
  - Per-process listener fires also yield into same continuation
  - `onTermination`: remove all listeners

### 4. Create `AudioActivityMonitor.swift`

- Public actor, injected `ProcessActivitySource`
- `activityStream() -> AsyncStream<[AudioProcess]>`:
  - Stores continuation in map keyed by UUID
  - Spawns monitoring task if first consumer
  - Monitoring task: emit initial snapshot, then `for await` on `processChanges()`, re-snapshot, diff, yield if changed
  - `onTermination`: remove continuation; if last consumer, cancel monitoring task
- `live()` static factory wiring `LiveProcessActivitySource`

### 5. Create `FakeProcessActivitySource.swift` in test Fakes/

- `Mutex<State>` holding current `[AudioProcess]` and `AsyncStream<Void>.Continuation?`
- `setProcesses(_:)` to update snapshot
- `sendChange()` to push notification
- `finish()` to end stream
- `waitUntilReady(timeout:)` with `Atomic<Bool>` signal

### 6. Create `AudioActivityMonitorTests.swift`

- Initial snapshot emitted on subscribe
- Process list change emits updated snapshot
- Running state change emits updated snapshot (only if IO state actually changed)
- No emission when snapshot is unchanged
- Multiple consumers each get events
- Stream finishes when fake finishes

## Tests

- `AudioActivityMonitorTests.initialSnapshot`: subscribing emits the current process list immediately
- `AudioActivityMonitorTests.processListChange`: adding/removing processes emits updated snapshot
- `AudioActivityMonitorTests.runningStateChange`: changing IO state of a process emits updated snapshot
- `AudioActivityMonitorTests.noEmissionWhenUnchanged`: change notification with identical snapshot does not yield
- `AudioActivityMonitorTests.multipleConsumers`: two streams both receive the same events
- `AudioActivityMonitorTests.streamFinishes`: fake finish causes stream to end
