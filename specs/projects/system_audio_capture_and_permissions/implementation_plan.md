---
status: complete
---

# Implementation Plan: System Audio — Robust Recording & Permission Handling

Ordered phases. Details live in `functional_spec.md`, `ui_design.md`, `architecture.md`.
Phases 1–3 are P1; Phase 4 is P2 (deferred). HW-verify gates are explicit — **no phase commits
before its gate is green on real Apple-silicon hardware.**

## Phases

- [x] **Phase 1 — Stage 1: Robust record pipeline** (`AudioCapture` + `RecordingController`)
  - Retry+settle on system-engine start and route/format reconnect; `-66565` → stop-track while
    preserving already-recorded audio (mic continues).
  - Remove the pre-record probe in `RecordingController.start()`; neuter `scheduleDenialCheck` so it
    drives no user-visible/persisted permission state (no durable "Denied").
  - **HW gate:** run `[DIAG]` diagnostics on hardware (AirPods/Bluetooth start + 44.1 kHz output
    mid-record) until the start/`-66565` failures are understood and fixed; resolve zero-loss-vs-
    stop-track for `-66565`.
  - Strip all `[DIAG]` logging, then commit. Mark `ac_*` manual tests not-run; add a system-audio
    device/sample-rate ManualTestApp case.
  - *Status:* engine work already implemented on-branch (uncommitted); mid HW-verification.
  - Depends on: — .

- [ ] **Phase 2 — Stage 2a: Permission mechanism (no UI)** (`AudioCapture` + `Permissions`)
  - `ProbeTonePlayer`; expose `observedNonZero`/`observedSystemAudio()`; add
    `AudioRecorder.probeSystemAudioWithTone(timeout:) -> Bool`.
  - `SystemAudioPermissionState`, `SystemAudioPermissionStore` (+ `UserDefaults` impl), `Permissions`
    wiring (`setSystemAudio` + launch restore from store).
  - `RecordingController.probeSystemAudioPermission()` + `AppCore.requestSystemAudioPermission()`
    single entry point. Unit tests via checker/store fakes.
  - **HW gate:** verify the tone reliably reaches `approved` when granted and stays
    `requestedNotVerified` when denied/revoked (incl. first-time prompt → Retry); tune tone params.
  - Depends on: Phase 1.

- [ ] **Phase 3 — Stage 2b: Permission UI** (`SettingsUI` + `OnboardingUI`)
  - Settings system-audio row: 4 states (incl. transient "Validating…"); Request Access / Retry /
    Validate / Fix permissions; no probe on view appear.
  - Onboarding step: same affordance, non-blocking, no Validate.
  - Shared Fix-permissions alert + System Settings deeplink (with fallback). View-model unit tests
    (state→display, button actions, no auto-probe).
  - Depends on: Phase 2.

- [ ] **Phase 4 — Stage 3: In-recording hint (deferred, P2)**
  - Subtle "No system audio detected — if your meeting audio has started, fix it" affordance →
    shared Fix-permissions alert; tolerant of benign silence; never writes persisted state.
  - Full design produced when this phase is spec'd. Depends on: Phase 3.
