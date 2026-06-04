---
status: complete
---

# Phase 6b: AudioLab Live Auto-Refresh (Streams Tab)

## Overview

The Streams tab in AudioLab currently requires a manual Refresh button to update process input/output status dots. This phase makes those dots update live.

**Poll vs. Notify Decision: Notification-based using `kAudioProcessPropertyIsRunning` (no polling), with a known limitation.**

Initial implementation attempted per-process listeners on `kAudioProcessPropertyIsRunningInput` and `kAudioProcessPropertyIsRunningOutput`. Live testing confirmed these properties do NOT fire notifications -- a known macOS bug reported on the Apple Developer Forums (thread 825780) where a developer confirmed that `kAudioProcessPropertyIsRunning` and `kAudioProcessPropertyDevices` fire correctly, but `IsRunningInput` and `IsRunningOutput` never trigger callbacks, even with wildcard listeners.

The fix: register one listener per process on `kAudioProcessPropertyIsRunning` (the general variant), which fires reliably when a process transitions between having no audio I/O and having any audio I/O (or vice versa). On each notification, re-read both `kAudioProcessPropertyIsRunningInput` and `kAudioProcessPropertyIsRunningOutput` to determine the specific input/output state.

**Known limitation of this approach:** `kAudioProcessPropertyIsRunning` only fires on the overall boolean transition (no-IO to IO, or IO to no-IO). It does NOT fire when a process that is already running output then starts or stops input (e.g. mic mute/unmute mid-call while speaker audio continues), because the overall "is running" boolean remains true throughout. In practice this means:
- **Join/leave call** (start/stop of all audio I/O) updates live.
- **Mic mute/unmute while the call's speaker audio is still active** does NOT update live; the Input dot requires a manual Refresh until Apple fixes the per-property notifications.

The manual Refresh button is retained as a fallback for this gap.

**Sources:**
- Apple Developer Forums thread 825780: https://developer.apple.com/forums/thread/825780 -- confirms IsRunningInput/IsRunningOutput do not fire, IsRunning does fire
- AudioCap by insidegui: https://github.com/insidegui/AudioCap -- reference project for per-process audio state; uses reactive reads rather than input/output-specific listeners

## Steps

1. **Add per-process listener helpers to `CoreAudioHelpers.swift`:**
   - New struct `ProcessPropertyListener` (`@unchecked Sendable`, holds `objectID`, `block`, `queue`, and `propertySelector` for removal).
   - `addProcessPropertyListener(processID:property:queue:handler:) -> ProcessPropertyListener?` -- registers a listener block on the given process object for the given property selector.
   - `removeProcessPropertyListener(_:)` -- removes the listener.
   - `processIOState(for:) -> (isRunningInput: Bool, isRunningOutput: Bool)` -- reads just the two I/O properties for one process.

2. **Extend `AudioStreamMonitor` to manage per-process listeners:**
   - Add `private var processListeners: [AudioObjectID: ProcessPropertyListener]` (one listener per process).
   - On `refresh()` (called when process list changes or on initial start), diff the current process IDs against the tracked set. Add listeners for new processes, remove listeners for departed ones.
   - Each listener registers on `kAudioProcessPropertyIsRunning`. On fire, the callback reads I/O state on `listenerQueue` (off main thread), then hops to `@MainActor` to apply the result.
   - Listener add/remove (`AudioObjectAddPropertyListenerBlock`) runs synchronously on `@MainActor` -- these are microsecond HAL registration calls. This eliminates TOCTOU races where concurrent reconciles could double-register listeners. The I/O-state reads in the callback stay on `listenerQueue`, off the main thread.
   - On `stopMonitoring()`, remove all per-process listeners.

3. **Keep StreamsView's Refresh button** as-is (fallback, necessary for the mid-call mute/unmute gap).

4. **Build and test.**

## Tests

- `ProcessPropertyListenerTests` -- verify `processIOState` returns defaults for invalid/system IDs, listener registration returns nil for invalid process IDs, `ProcessPropertyListener` struct stores fields correctly, and remove with invalid ID does not crash.
