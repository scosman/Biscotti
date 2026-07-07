---
status: complete
---

# System Audio: Robust Recording & Permission Handling

## Background

Split out and expanded from the `system-audio-capture-fragility` task (itself a follow-up to the
mic-recording fix `effad40`). Real-hardware testing surfaced intermittent system-audio capture
failures — "System engine start failed" (~1 of 3 record sessions) and `-66565` on output-device
route changes. Investigation revealed the manual-test harness runs a redundant permission
**probe** (create + destroy a Core Audio process tap) immediately before recording, which likely
manufactures the HAL device-graph churn behind the start failures. Fixing this well means both
hardening the record pipeline and rethinking how/when we probe for system-audio permission.

## Step 0 (resolved) — Is there a permission API? No.

Verified against current Apple APIs and the repo's `specs/research/permissions/README.md`:

- **No public API to query/preflight** whether the app holds system-audio-capture permission
  without creating a tap. (`CGPreflightScreenCaptureAccess` = screen recording only;
  ScreenCaptureKit = screen recording; `AVCaptureDevice.authorizationStatus(for: .audio)` = mic
  only; no Core Audio HAL property exposes it.)
- **No public API to explicitly request** it — the TCC prompt only appears when a process tap is
  actually created.
- Creating a Core Audio tap gates against the dedicated **`kTCCServiceAudioCapture`** ("System
  Audio Recording Only") service — distinct from microphone and screen recording. Notably it
  needs **no app restart** after granting and has **no monthly re-auth** (unlike screen recording).
- A *private* TCC API (`TCCAccessPreflight` / `TCCAccessRequest("kTCCServiceAudioCapture")`) can
  query/request, but it is private — App-Store-disqualifying and breakable. Not used.

→ The probe approach is **not moot**. The project's "save last-known-granted state as a hint +
offer Validate" design is the correct response to this API gap.

## Stage 1 — Robust record pipeline (largely the in-progress task work)

- **Probe removal when starting a recording** — starting a recording must not perform a permission
  probe; just start.
- **Other fixes** — retry + settle resilience, client-format renegotiation handling on
  device/sample-rate changes, and `.public` diagnosable error logging. A robust record pipeline.
- **Diagnostics and hardware checks** to confirm it actually works — interactive, on real
  Apple-silicon hardware.
- **Clean up diagnostics, commit.**

## Stage 2 — Probe / permission cleanup

- **De-couple probe and recording**
  - Starting to record a meeting should **not** do a probe, just start (see Stage 1).
  - **Onboarding** should continue to do a probe, and only a probe — using a clean probe API
    (the current separation between probe and recording may be poor; tidy it).
  - **Settings** can use a probe, with the behavior described below.
- **Save successful system-audio permission to defaults**
  - We never save "system audio permission granted" and can't query it. Add a `UserDefaults`
    flag for it. **NOT** a setting in SwiftData — this must never sync across devices. Imperfect
    (the user could revoke it in System Settings) but a good hint of state.
- **Settings fixes**
  - Settings has long shown "Not requested" for system audio on subsequent launches, even when it
    is approved.
  - It should use the default to show **"Approved"** when the last-known state from the default
    indicates approval. However, because we can't fully trust the default, the Approved state gets
    a **"Validate"** button that runs a probe and then updates the default. (Unlike other
    permissions, we can't trust the default, so "Validate" is available on "Approved.") The "Not
    requested" state stays the same, but only shows when the default indicates not-approved.
  - **Don't probe on opening Settings** — it flashes the recording indicator. Validation is
    explicit (the user clicks Validate).
