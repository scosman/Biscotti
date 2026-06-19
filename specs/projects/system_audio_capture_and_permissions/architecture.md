---
status: complete
---

# Architecture: System Audio — Robust Recording & Permission Handling

Single-doc architecture (no separate component files). Maps to the three stages. Concrete
signatures are given so coding agents execute, not design. Existing symbols are cited where the
work modifies them.

## Module map (where things live)

| Concern | Package / module | New or modify |
|---|---|---|
| System capture engine, retry/settle, format renegotiation | `Packages/AudioCapture` → `LiveSystemCaptureEngine`, `AudioRecorder` | modify (Stage 1, mostly done) |
| Probe tone generator | `Packages/AudioCapture` → new `ProbeTonePlayer` | new (Stage 2) |
| Tone-probe API + non-zero signal exposure | `Packages/AudioCapture` → `AudioRecorder`, `LiveSystemPermissionChecker` | modify (Stage 2) |
| System-audio permission state + persistence | `Packages/BiscottiKit/Sources/Permissions` | modify + new store (Stage 2) |
| Probe orchestration / wiring | `BiscottiKit` → `RecordingController`, `AppCore` | modify (Stage 1 + 2) |
| Settings row, alert, deeplink | `BiscottiKit/Sources/SettingsUI` | modify (Stage 2) |
| Onboarding step | `BiscottiKit/Sources/OnboardingUI` | modify (Stage 2) |
| In-recording hint | `BiscottiKit` (recording surface) | new (Stage 3, deferred) |

Thin-app rule holds: all logic is in packages; the app target only composes.

---

## Stage 1 — Robust record pipeline (engine)

Most of this is already implemented on-branch (`AudioRecorder` + `LiveSystemCaptureEngine`). The
design of record:

### 1.1 Start resilience — `AudioRecorder.startSystemEngineWithRetry`
- Bounded retries (currently 2 retries / 3 attempts) with a settle delay (~250 ms) between attempts,
  to absorb HAL device-graph reconfiguration churn (post-VPIO reclock, post-probe-teardown).
- On exhaustion: throw; the orchestrator keeps the mic track and logs `.public`.

### 1.2 Route/format-change resilience — `LiveSystemCaptureEngine.reconnect` + `AudioRecorder.reconnectSystemEngineWithRetry`
- `teardownHardware()` → settle delay (~200 ms) → re-create tap/aggregate → renegotiate client
  format. Bounded retries (~2) on reconnect.
- **`-66565` (client-format renegotiation) fallback:** stop the system track via
  `clientFormatFailed`, **preserving all audio already written** (the old `eraseFile` reopen is
  removed). Mic keeps recording.
  - **Open HW item:** confirm whether zero-loss renegotiation is achievable (preferred) vs. this
    stop-track fallback. Decided from the Stage-1 diagnostics run; the fallback is the safe default.

### 1.3 Remove the pre-record probe — `RecordingController.start()`
- Delete the `probeSystemAudioPermission(recorder:)` call (~line 131–132). Recording still creates
  its real tap (surfaces the TCC prompt on first use as before). This removes the redundant
  destroy→recreate churn before each record.
- **Neuter the in-recording denial side effect:** `scheduleDenialCheck` must no longer drive any
  user-visible/persisted permission state (no durable "Denied"). For Stage 1 it becomes inert (the
  2 s all-zero infra may be reused by Stage 3). It does not call into `Permissions`.

### 1.4 Diagnostics & logging
- Temporary `[DIAG]` logging (`.notice`, `.public`) across start/teardown/route-change — already
  added — used for the HW run, then **removed before the Stage-1 commit**.
- Permanent: all failure logs are `.public` (real OSStatus/errors), never `<private>`.

---

## Stage 2 — Tone-probe, state model, persistence, UI

### 2.1 Permission state type (new) — `Permissions/SystemAudioPermissionState.swift`

System audio gets its **own** state type (the shared `PermissionState` keeps `.denied`, which we
forbid here, and lacks the "requested but unverified" notion):

```swift
public enum SystemAudioPermissionState: String, Sendable, CaseIterable {
    case notRequested            // never probed
    case requestedNotVerified    // probed/probing, approval not confirmed  → UI "Not approved"
    case approved                // tone captured → granted

    public var displayText: String {
        switch self {
        case .notRequested:         "Not Requested"
        case .requestedNotVerified: "Not approved"
        case .approved:             "Granted"
        }
    }
}
```

The shared `PermissionState` stays for mic/calendar/notifications. The Settings row gains a
system-audio-specific variant (see 2.6).

### 2.2 Persistence seam (new) — `Permissions/SystemAudioPermissionStore.swift`

```swift
protocol SystemAudioPermissionStore: Sendable {
    func load() -> SystemAudioPermissionState
    func save(_ state: SystemAudioPermissionState)
}

struct UserDefaultsSystemAudioPermissionStore: SystemAudioPermissionStore {
    let defaults: UserDefaults          // .standard (device-local, non-syncing)
    private let key = "systemAudioPermissionState"
    func load() -> SystemAudioPermissionState {
        defaults.string(forKey: key).flatMap(SystemAudioPermissionState.init(rawValue:)) ?? .notRequested
    }
    func save(_ state: SystemAudioPermissionState) { defaults.set(state.rawValue, forKey: key) }
}
```

- **`UserDefaults.standard` only — never SwiftData/`AppSettings`** (those sync via CloudKit; TCC is
  device-local). This is the project's single `UserDefaults` usage; the protocol seam keeps
  `Permissions` unit-testable with an in-memory fake.
- Persist on every transition; the store mirrors the live state. `requestedNotVerified` persists too
  (a relaunch after an unconfirmed probe correctly shows "Not approved" + Retry/Fix).

### 2.3 `Permissions` changes — `Permissions/Permissions.swift`
- `systemAudio` becomes `SystemAudioPermissionState` (was `PermissionState`), injected store:
  ```swift
  private let systemAudioStore: SystemAudioPermissionStore
  public private(set) var systemAudio: SystemAudioPermissionState
  // init: systemAudio = systemAudioStore.load()
  ```
- Replace `noteSystemAudio(_:)` with `setSystemAudio(_ state:)` that updates the observable property
  **and** persists via the store.
- `refresh()` continues to skip system audio (no API); the persisted value is the source of truth on
  launch (fixes "always Not Requested").

### 2.4 Probe tone generator (new) — `AudioCapture/ProbeTonePlayer.swift`

Plays a continuous **low-amplitude** signal to the **default output** for the probe window, so the
global tap captures non-zero samples. Because the tap reads the digital system mix with
`muteBehavior = .unmuted`, the amplitude can be tiny (effectively inaudible) yet still register as
non-zero regardless of the user's hardware volume or mute.

```swift
final class ProbeTonePlayer {
    func start() throws    // begin tone to current default output
    func stop()            // idempotent
}
```
- Implementation: `AVAudioEngine` + `AVAudioSourceNode` rendering a low-amplitude sine (engine
  outputs to the system default output). Separate from the mic VPIO engine (not running during a
  probe).
- **Tone parameters are HW-tuned** (see Risks): primary = ultra-low amplitude in the audible band
  (~1 kHz, amplitude small enough to be inaudible but above any noise gate); fallback = a
  high-frequency (~18–19 kHz) tone or a slightly louder brief blip if the low-amplitude tone proves
  unreliable on some output paths (e.g. Bluetooth codecs).

### 2.5 Tone-probe API (modify) — `AudioCapture`
- Expose the instantaneous non-zero signal from the checker (today `LiveSystemPermissionChecker`
  only offers `probableDenied()` which needs 2 s):
  ```swift
  // LiveSystemPermissionChecker
  var observedNonZero: Bool { get }     // mirrors hasNonZero
  // AudioRecorder
  func observedSystemAudio() -> Bool
  ```
- New probe method (replaces the bare `requestPermissions` start/stop for system audio):
  ```swift
  /// Starts a fresh system tap + plays the probe tone; returns true as soon as non-zero
  /// system audio is observed, false after `timeout`. Always tears down tap + tone.
  func probeSystemAudioWithTone(timeout: Duration = .seconds(5)) async -> Bool
  ```
  Flow: start system engine (fresh tap → prompt on first use) → `ProbeTonePlayer.start()` → poll
  `observedSystemAudio()` until true or timeout → stop tone → stop engine → return.
  - Each call uses a **fresh** tap, so a Retry after a first-time grant naturally captures the tone
    (covers the "tap created while prompt pending stays silent" case — no special logic).
  - The mic auth check in the old `requestPermissions` (mic uses a real API) stays available for the
    mic path but is **not** part of this system-audio probe.

### 2.6 Orchestration & wiring
- **`RecordingController.probeSystemAudioPermission()`** (the probe-only path; rename/replace
  `probeSystemAudioAndInferState`):
  ```swift
  func probeSystemAudioPermission() async {
      permissions.setSystemAudio(.requestedNotVerified)          // on start
      let observed = await makeRecorder().probeSystemAudioWithTone(timeout: .seconds(5))
      permissions.setSystemAudio(observed ? .approved : .requestedNotVerified)
  }
  ```
  Never sets a durable denied; only `approved` or stays `requestedNotVerified`.
- **`AppCore.requestSystemAudioPermission()`** → calls the above. Single entry point for onboarding
  and Settings (Request Access / Retry / Validate all route here).
- `RecordingController.start()` no longer probes (Stage 1).

### 2.7 Settings UI — `SettingsUI`
- `SettingsViewModel`: expose `systemAudioState: SystemAudioPermissionState` (from
  `core.permissions.systemAudio`) and `isValidatingSystemAudio: Bool` (true while a probe runs).
- System-audio row renders per `ui_design.md` §1: `not_requested → [Request Access]`,
  `validating → "Validating…" + spinner (disabled)`, `requested_not_verified → "Not approved"
  [Retry] [Fix permissions]`, `approved → "Granted ✓" [Validate]`.
- **No probe on view appear.** Buttons call `AppCore.requestSystemAudioPermission()`.
- **Fix permissions** → present the shared alert (2.9).

### 2.8 Onboarding UI — `OnboardingUI`
- System-audio step uses the same state/affordance; **non-blocking** ([Continue]/[Skip] always
  available). No Validate button (Settings-only). Calls the same `AppCore` entry point.

### 2.9 "Fix permissions" alert + deeplink (shared)
- A shared SwiftUI alert (copy per `ui_design.md` §2) presented by Settings/Onboarding (and Stage 3
  later).
- Deeplink: `NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)`.
  Verify the anchor on the target macOS at implementation; **fallback** to the Privacy & Security
  root URL if the anchor is unavailable. No app restart needed (`kTCCServiceAudioCapture`).

---

## Stage 3 — In-recording hint (deferred, P2)
Sketch only (full design when spec'd): a low-emphasis affordance in the recording surface, gated on
sustained all-zero system audio (reusing the 2 s checker infra from 1.3), tolerant of benign
silence, tapping into the shared Fix-permissions alert. **Never writes the persisted state.**

---

## Error handling & logging
- System start/reconnect failures: bounded retry, then graceful degradation (mic continues),
  `.public` logs with real OSStatus.
- Probe failures (engine won't start, tone won't play): treated as "not observed" → state stays
  `requestedNotVerified` (never crashes a probe; log `.public`).
- No throwing across the probe boundary to the UI — `probeSystemAudioWithTone` returns `Bool`.

## Testing strategy
- **AudioCapture (unit, `swift test`):**
  - Retry/settle for start + reconnect via `FakeCaptureEngine` (already present; extend for the
    probe path).
  - `probeSystemAudioWithTone` timeout/observed logic with a fake checker (inject `observedNonZero`
    true/false; assert returns true early vs. false on timeout). The real tone+tap capture is HW-only.
- **Permissions (unit):** in-memory `SystemAudioPermissionStore` fake — transitions
  (start→requestedNotVerified, observed→approved, timeout→requestedNotVerified), launch restore from
  store, no-denied invariant.
- **Settings/Onboarding view models (unit):** state→display mapping; button actions invoke the probe
  entry point; `isValidating` toggles; no probe on load.
- **Manual (ManualTestApp, HW):** (a) Stage 1 — system-audio device/sample-rate transitions
  (AirPods/Bluetooth start, 44.1 kHz output mid-record); (b) Stage 2 — tone-probe grant/deny/revoke
  flow incl. first-time prompt + Retry. Mark `ac_*` steps not-run per the staleness rule.
- Heavy/HW paths are not gated in CI (consistent with repo policy).

## Risks & HW-verify items
1. **Tone reliability (linchpin):** an ultra-low-amplitude tone must (a) stay inaudible and (b) still
   register as non-zero through all output paths (built-in, USB, Bluetooth codecs, AirPlay). HW-tune
   amplitude/frequency; fallback to ~18–19 kHz or a brief louder blip. Verified before Stage 2 commit.
2. **First-time prompt timing:** a pre-grant tap may stay silent; covered by Retry (fresh tap). Verify.
3. **Stage 1 `-66565`:** confirm stop-track-preserve vs. achievable zero-loss renegotiation from the
   HW diagnostics. Verified before Stage 1 commit.
4. **Deeplink anchor** may differ by macOS version; fallback to Privacy root.

## Decisions made (for your review)
- Dedicated `SystemAudioPermissionState` (not extending the shared enum). 
- `UserDefaults` store behind a protocol seam (testable), single key.
- Persist `requestedNotVerified` across launches (relaunch shows "Not approved" honestly).
- Tone via `AVAudioEngine`/`AVAudioSourceNode`, ultra-low amplitude primary + HF/blip fallback.
- Single architecture doc; no component sub-docs.
