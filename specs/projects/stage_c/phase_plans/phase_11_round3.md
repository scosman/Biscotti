---
status: in-progress
---

# Phase 11 — Round 3 (third hardware pass)

Third batch of human-review feedback from running V1 on real Apple-silicon
hardware. Executed as sequential sub-agent batches (coding → green
`precommit_checks` → spec-aware CR → commit), `make ci` stays green. Each batch
is one commit. Continues `phase_11_round2.md` (B1–B9).

---

## N1 — Link-calendar-event dialog searches near recording time (VERIFY)
- [x] **Re-reported:** "Link calendar event"/"Choose a calendar event" dialog
  filters to *upcoming* instead of events **near the recording time**. Should be
  sorted by **delta from recording start**, limited to events whose **start time
  is within 1.5h** of recording start.
- **Already correct (B9, commit bf8abd9).** Verified the full path:
  `MeetingDetailView` → `presentAssociationCorrection()` → `loadNearbyEvents()`
  feeds `detail?.date` (the recording time) to `core.eventsNear` →
  `CalendarService.eventsNear` (±1.5h start-time window, post-filtered, sorted by
  Δ). The user hit a pre-B9 build. Only fix needed: a stale `AppCore.eventsNear`
  doc comment said "±2h" → corrected to ±1.5h.

## N2 — Sidebar doesn't refresh after linking a calendar event
- [x] **Bug:** linking a calendar event updates the title in Meeting Detail
  **instantly**, but the **sidebar list row** keeps the old title until you
  navigate away and back. The sidebar list must refresh immediately on
  association.
- **Fixed:** `MeetingDetailViewModel.correctAssociation(eventKey:)` now calls
  `await core.reloadSummaries()` after `load()` (covers link + unlink via
  delegation). Commit: R1.

## N3 — Linking a calendar event wrongly sets the `editedTitle` flag
- [x] **Bug:** after linking a calendar event, subsequent **event changes no
  longer update the title** — the association path appears to set
  `editedTitle = true`. The flag is reserved for **human manual edits only**;
  calendar association is a side-effect edit and must **not** set it (per B1
  rules: association sets title *unless* `editedTitle`, only manual edit sets the
  flag).
- **Root cause (not the association path):** `flushNotes()` runs on every
  `onDisappear` and unconditionally called `saveTitle()` → `store.setTitle()` →
  `editedTitle = true`. So merely *viewing* any meeting and leaving permanently
  flagged its title as user-edited, blocking all future calendar auto-titles.
- **Fixed:** `saveTitle()` now early-returns when the trimmed title equals the
  stored title — it only persists (and sets the flag) on a genuine change. Commit:
  R1. Regression tests assert the unchanged-title path keeps `editedTitle=false`
  and a later association still updates the title.

## N4 — Notification permission prompt style (QUESTION)
- [x] User asks: the notification approval shows as a **notification with
  approve/deny**, unlike other permissions which are modal **alerts**. Is that
  normal? → **Yes, normal. No code change.** We request standard non-provisional
  auth (`requestAuthorization([.alert, .sound])`, LiveNotificationCenter.swift:19).
  macOS deliberately presents *notification* permission as a notification-style
  banner with Allow/Don't Allow — unlike mic/calendar/screen-recording modal TCC
  alerts. That difference is Apple's and isn't configurable. Getting a prompt at
  all confirms B7 fixed the "no prompt ever" bug.

## N5 — Time-to-upcoming rounding (off by one)
- [ ] **Bug:** at 4:28.x a meeting 1.x min away shows **"1 min"**; should
  **round up** to "2 min". Applies to all relative upcoming times (menu bar +
  sidebar). Switch the countdown formatter from floor/round to **ceil**.

## N6 — Sidebar upcoming section: 2-line rows + up to 5
- [ ] Make the **upcoming** section rows **2 lines**: **title** on line 1, the
  rest (time/relative) on line 2.
- [ ] Allow up to **5** upcoming events (currently showing 3 — may be a
  time-range limit, acceptable if so, but raise the display cap to 5).
