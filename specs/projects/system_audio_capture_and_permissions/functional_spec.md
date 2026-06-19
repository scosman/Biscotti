---
status: complete
---

# Functional Spec: System Audio — Robust Recording & Permission Handling

## Goal & context

Make Biscotti's **system-audio capture** robust and its **permission handling** honest. Two
problems, surfaced on real Apple-silicon hardware:

1. **Capture fragility:** intermittent "System engine start failed" (~1 of 3 sessions) and
   `-66565` on output-device route changes break a recording's system track. A redundant
   permission *probe* run immediately before recording manufactures HAL device-graph churn that
   contributes to the start failures.
2. **Dishonest permission state:** macOS exposes **no API** to query or request system-audio
   (Core Audio tap / `kTCCServiceAudioCapture`) permission. The only signal is whether the tap
   captures non-zero audio. Today system-audio status is in-memory only and resets to "Not
   Requested" on every launch, even when granted.

The work is split into three stages (= implementation phases), shipped in order. Stage 3 is P2.

### Key validated facts (don't re-derive)

- **No public API** to query/preflight or explicitly request system-audio permission. Private TCC
  (`TCCAccessPreflight`/`Request`) exists but is App-Store-disqualifying and fragile — **not used.**
- Core Audio taps gate on the dedicated **`kTCCServiceAudioCapture`** service ("System Audio
  Recording Only"): distinct from mic and screen recording, **no app restart**, **no monthly
  re-auth**.
- The system tap is **global with no exclusions** (`CATapDescription(monoGlobalTapButExcludeProcesses: [])`,
  `muteBehavior = .unmuted`) → it captures **all** system output **including Biscotti's own**, even
  when the output device is muted. This is what makes a self-played **test tone** a reliable probe.
- The only "granted" evidence is `LiveSystemPermissionChecker`: `hasNonZero` flips true on the first
  non-zero sample; `probableDenied()` is true only after ≥2 s of all-zero audio. A *denied* tap
  still delivers (all-zero) buffers; a *granted-but-silent* system also looks all-zero — so silence
  alone is ambiguous. **The test tone removes this ambiguity.**

---

## Stage 1 — Robust record pipeline

The in-progress branch work. Hardens system capture against device/sample-rate changes and stops
the redundant pre-record probe.

### 1.1 Remove the pre-record probe
- `RecordingController.start()` must **not** run a system-audio permission probe before recording.
  Recording still creates its real tap, which surfaces the TCC prompt the first time as before.
- The legacy in-recording 2-second denial check (`scheduleDenialCheck`) is **decoupled from any
  persisted/displayed permission state** in this project: it must **never** write a `denied`
  verdict that the user sees as a durable state. (Its replacement is the subtle Stage 3 hint.) For
  Stage 1 it may remain inert or be removed; it must not produce a user-visible "Denied."

### 1.2 Start resilience (Symptom 1)
- On system-engine start failure, **retry with a settle delay** (bounded attempts) before giving
  up — to absorb HAL device-graph reconfiguration churn (e.g. after VPIO reclocks the output, or
  after a probe's tap/aggregate teardown).
- If all attempts fail: the mic track continues recording; the failure is logged at `.error` with
  **`.public`** detail (real OSStatus/error, not `<private>`).

### 1.3 Route / sample-rate change resilience (Symptom 2)
- On default-output-device or format change mid-recording, **reconnect with a settle delay**
  (bounded retries), renegotiating the client format.
- If client-format renegotiation ultimately fails (`-66565` family): **stop the system track while
  preserving all audio already written**, and keep the mic recording. Log `.public`, explicit
  about what was and wasn't preserved.
  - *Note:* the previous behavior erased the entire session's system audio (file reopened with
    `eraseFile`) — that path is removed. **Open question to confirm on HW:** whether zero-loss
    renegotiation is achievable (preferred) vs. this stop-track fallback. Decided after diagnostics.

### 1.4 Diagnostics & hardware verification (interactive)
- Temporary, greppable diagnostic logging (`[DIAG]` token, `.notice`, `.public`) across the
  system-capture start/teardown/route-change sites, used to root-cause on real hardware.
- A human runs the app on Apple silicon, reproduces device/sample-rate transitions (incl. AirPods/
  Bluetooth and 44.1 kHz output), and captures logs until the failures are understood and the fix
  is confirmed.
- **Then** the diagnostic logging is removed and the stage is committed. No commit before HW
  verification.

### 1.5 Out of scope for Stage 1
- The **mic** default-input-device change bug (AirPods ↔ built-in) — tracked separately
  (`mic-default-input-device-change` backlog note). Do not touch `LiveMicCaptureEngine`.

---

## Stage 2 — Tone-probe, permission persistence, Settings & onboarding

Replaces the unreliable silence probe with a deterministic **tone-probe**, persists the verdict,
and fixes the Settings/onboarding permission experience.

### 2.1 Permission state model (system audio)

Three states — **there is no `denied`**. We can never cleanly distinguish "denied" from "granted
but slow/silent," so we never claim it.

- **`not_requested`** — never probed. UI: "Not Requested".
- **`requested_not_verified`** — a probe has run (or is running) but approval was not confirmed.
  UI label: **"Not approved"**. This single state deliberately collapses "prompt pending,"
  "denied," and "granted but unconfirmed" — we don't try to tell them apart.
- **`approved`** — the tone-probe captured non-zero audio. UI: "Granted".

Transitions (identical in onboarding and Settings):
1. The instant a tone-probe **starts** → set **`requested_not_verified`** (persisted).
2. If the tap captures the tone (any non-zero sample) within the window → set **`approved`**
   (persisted); the probe may end early.
3. If the probe **times out after 5 s** with all-zero → remain **`requested_not_verified`**.

No path sets a durable "denied." A **revocation** simply surfaces as a later re-probe that times
out → `requested_not_verified`.

### 2.2 The shared tone-probe helper
One helper, used by onboarding and Settings only (**never** by the recording path):
1. Set state → `requested_not_verified`.
2. Start the system engine (creates the global tap; surfaces the TCC prompt on first use).
3. Play a **brief, low-amplitude, near-inaudible tone** to the current default output across the
   window (the tone must outlast tap/buffer latency).
4. Watch the tap via the existing checker: first non-zero sample ⇒ **`approved`** (end early).
5. Otherwise after **5 s** ⇒ stop; state stays **`requested_not_verified`**.
6. Stop the engine.

Notes:
- A tap created while a **first-time prompt is still pending** can stay silent even after the user
  grants. This needs **no special in-probe logic**: it times out to `requested_not_verified`, and
  the **Retry** button (§2.4) runs a fresh probe whose new (post-grant) tap captures the tone →
  `approved`. There is no recording-mode codepath for this — recording never probes.
- Each probe briefly flashes the macOS recording indicator (any tap creation does). Acceptable —
  every probe is user/onboarding-initiated, never automatic.

### 2.3 Persistence (the durable hint)
- Persist the current state to a **non-syncing `UserDefaults` flag** (the device-local hint),
  behind a testable seam in the `Permissions` module.
- **Never SwiftData / `AppSettings`** — those can sync via CloudKit; TCC grants are device-local.
- `Permissions` reads it on launch, so system-audio status **survives relaunch** (fixes the
  "always Not Requested" bug).
- It is a hint, not ground truth: `approved` can go stale if the user revokes in System Settings —
  **Validate** re-checks it.

### 2.4 Shared "Not approved" affordance (onboarding **and** Settings)
Whenever the state is `requested_not_verified`, both surfaces show the same thing:

> **Not approved** · [Retry] · [Fix permissions]

- **Retry** → re-runs the 5 s tone-probe.
- **Fix permissions** → an alert that explains it is **likely a denied permission**, how to fix it,
  and provides a **deeplink** to the System Settings "System Audio Recording" pane.

### 2.5 Onboarding
- The system-audio onboarding step runs the shared tone-probe ("a probe, and only a probe") and
  shows the shared "Not approved" affordance (§2.4) when not yet `approved`.
- Onboarding **does not hard-block** on system-audio approval — the user may proceed and grant
  later (exact flow finalized in UI design).

### 2.6 Settings UI behavior
Driven by the persisted state; **no automatic probe on opening Settings** (avoids the recording-
indicator flash):

| Persisted state | Shows | Action(s) |
|---|---|---|
| `not_requested` | "Not Requested" | **Request Access** → starts the tone-probe |
| `requested_not_verified` | **"Not approved"** | **Retry** (5 s probe) · **Fix permissions** (alert + deeplink) |
| `approved` | "Granted" | **Validate** → 5 s probe; on timeout (e.g. revoked) it becomes `requested_not_verified` |

- "Request Access", "Retry", and "Validate" are the **same** tone-probe — only the entry state and
  button label differ.
- During an active probe the UI may show a transient "Validating…" affordance (a UI-design detail);
  the underlying persisted state is `requested_not_verified` until the result lands.

### 2.7 Out of scope for Stage 2
- The in-recording passive detection / hint (that's Stage 3).
- Any private TCC APIs. Any durable "denied" state.

---

## Stage 3 — In-recording "no system audio" hint (P2, deferred)

A passive, in-meeting affordance for the case where a recording is capturing **no** system audio
(likely revoked permission — but ambiguous). Its own stage at the end because it is **hard to get
right** and must not cry wolf.

### 3.1 Behavior
- During a live recording, detect a sustained absence of system audio (all-zero) using the existing
  checker — but **tolerant of benign causes**: meeting hasn't started, no audio playing yet, the
  meeting app is closed, the user is on mute. Must avoid false positives (do **not** assume "no
  permission" just because nothing is playing).
- **Never writes the persisted permission flag.** This is an in-session hint only.

### 3.2 UX
- **Subtle, not error-styled.** Not a red alert. Tone like:
  *"No system audio detected — if your meeting has started, [click here]."*
- Clicking reveals an **alert** explaining how to fix it in System Settings, **ideally with a
  deeplink** to the System Audio Recording pane.

### 3.3 Open (resolved when Stage 3 is spec'd)
- Exact detection thresholds/timing and the precise affordance placement are deferred to the
  Stage 3 design.

---

## Cross-cutting constraints
- Apple silicon, macOS 15+ only.
- No private APIs (App Store path must remain open); no SwiftData for the device-local flag.
- All system-capture failure logging is `.public` and diagnosable.
- Swift-package-first: behavior lives in `Packages/AudioCapture` and `BiscottiKit` (Permissions,
  SettingsUI, OnboardingUI); the app target stays thin.

## Edge cases & error handling
- **Probe while output muted:** tap is `.unmuted` → tone still captured → `approved`.
- **Probe with another app already playing audio:** also non-zero → `approved` (correct).
- **Transient all-zero during Validate:** worst case the state shows "Not approved" momentarily;
  **Retry** recovers. There is no false "denied" because no `denied` state exists.
- **First-time prompt still pending at timeout:** lands in `requested_not_verified`; after the user
  grants, **Retry** runs a fresh post-grant probe → `approved` (§2.2).
- **Tap silent until re-created post-grant:** covered by **Retry** (fresh tap) — no special logic.
- **System start fails entirely (recording):** mic keeps recording; `.public` error; Stage 1 retry
  first.
- **Stale `approved` (revoked since last launch):** surfaced by **Validate**, and in-session by the
  Stage 3 hint.

## Assumptions & risks
- **Tone capture (confirmed):** global no-exclusion tap captures self audio. If the tap config ever
  adds self-exclusion, the probe needs a separate global-inclusive tap (fallback noted; not needed
  today).
- **HW-verify the linchpins:** (a) Stage 1 fixes actually resolve the start/`-66565` failures;
  (b) the tone-probe reliably reaches `approved` when permission is granted — including that a
  fresh post-grant probe (via Retry) captures the tone. Both confirmed on real hardware before
  their stage commits.
