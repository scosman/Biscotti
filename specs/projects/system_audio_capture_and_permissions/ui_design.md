---
status: complete
---

# UI Design: System Audio — Permission Handling

Only Stage 2 (and a Stage 3 sketch) has UI. Stage 1 is engine/plumbing — no UI. The guiding rule:
**never alarming.** "Not approved" is a neutral state with clear next actions, not an error.

## Scope
1. Settings → Permissions → **System Audio** row (the main work).
2. The **"Fix permissions"** alert + System Settings deeplink (shared by Settings, onboarding, and
   later Stage 3).
3. Onboarding → **System Audio** step (reuses the same affordance).
4. Stage 3 **in-recording hint** (sketch only; P2).

All three probe entry points (Request Access / Retry / Validate) run the **same 5 s tone-probe**;
only the entry state and button label differ. No probe ever runs automatically (never on Settings
open) — only on an explicit tap or the onboarding step.

---

## 1. Settings — System Audio permission row

Reuses the existing permission-row layout (label + status text + trailing control), consistent with
the Microphone/Calendar/Notifications rows. Four render states:

```
not_requested          System Audio    Not Requested            [ Request Access ]
validating (transient) System Audio    Validating…   ◌          (controls disabled)
requested_not_verified System Audio    Not approved             [ Retry ] [ Fix permissions ]
approved               System Audio    Granted ✓                [ Validate ]
```

Behavior:
- **Request Access / Retry / Validate** → start the 5 s tone-probe. While it runs, the row shows
  **"Validating…"** with a spinner and disabled controls (prevents a flicker to "Not approved"
  mid-probe). A brief near-inaudible tone plays and the macOS recording indicator flashes — expected
  for a user-initiated check.
- Result: tone captured → **Granted ✓**; 5 s timeout → **Not approved**.
- **Validate** on a stale `approved` that has been revoked → times out → row drops to **Not
  approved** (revocation surfaced without ever saying "Denied").
- The two-button **Not approved** state is the only row with two trailing controls; if width is
  tight, **Fix permissions** may render as a secondary/link-style button under the row.

## 2. "Fix permissions" alert (shared)

Triggered by **Fix permissions**. Standard macOS alert:

- **Title:** "Allow Biscotti to record system audio"
- **Body:** "Biscotti couldn't confirm permission to record your computer's audio. macOS doesn't let
  apps re-ask directly — turn it on in System Settings: Privacy & Security → **System Audio Recording**,
  enable **Biscotti**, then return and tap Retry."
- **Buttons:** **[Open System Settings]** (primary, deeplink) · **[Done]**

Deeplink target: the System Audio Recording privacy pane
(`x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture` — exact anchor
verified at implementation; fall back to the Privacy & Security root if the anchor is unavailable on
the running macOS version). No app restart is needed after enabling (`kTCCServiceAudioCapture`).

## 3. Onboarding — System Audio step

Same wizard styling as the other onboarding permission steps. Reuses §1's states and §2's alert.

```
┌───────────────────────────────────────────────┐
│  Record meeting audio                          │
│  Biscotti captures the other side of your      │
│  call from your speakers/headphones.           │
│                                                 │
│  ▸ before probe:    [ Request access ]          │
│  ▸ validating:      Validating…  ◌              │
│  ▸ approved:        Granted ✓                   │
│  ▸ not approved:    Not approved                │
│                     [ Retry ] [ Fix permissions ]│
│                                                 │
│                         [ Skip ]   [ Continue ] │
└───────────────────────────────────────────────┘
```

- **Non-blocking:** [Continue] is always enabled (and [Skip] present) — the user can grant later in
  Settings. Onboarding "does a probe, and only a probe"; it never starts a recording.
- On **approved**, the step may auto-enable Continue / show the checkmark.
- **No "Validate" button here** — Validate is Settings-only (for re-checking an already-granted
  state). In onboarding, `approved` simply shows **Granted ✓**.

## 4. Stage 3 — in-recording hint (sketch only, P2)

Deferred; thresholds, timing, and exact placement are decided when Stage 3 is spec'd. Intent:

- **Placement:** within the active-recording surface (menu-bar popover / recording window), a
  low-emphasis line — **not** a red banner.
- **Copy (illustrative):** "No system audio detected — if your meeting audio has started, **fix it**."
  ("fix it" is the affordance.)
- **Tap →** the same **Fix permissions** alert (§2).
- Must tolerate benign silence (meeting not started, nothing playing, app on mute) — appears subtly
  and only after a sustained absence; never writes the persisted permission state.

---

## UX notes / pushback
- **Reuse, don't reinvent:** the row matches existing permission rows; the alert is a standard macOS
  alert; the deeplink uses the OS-standard System Settings URL scheme.
- **"Validating…" matters:** without it, every probe would briefly flash "Not approved" before
  resolving — jarring. The transient keeps the row honest without alarming.
- **Neutral language throughout:** "Not approved" (not "Denied"/"Error"). The only place we assert a
  likely denial is inside the Fix-permissions alert, paired with the remedy.
- **Discoverability:** "Fix permissions" is always present in the not-approved state, so a user who
  silently denied has an obvious path back — no hunting in System Settings unaided.
