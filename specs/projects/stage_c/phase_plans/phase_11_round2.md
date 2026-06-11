---
status: in-progress
---

# Phase 11 — Round 2 (second hardware pass)

Second batch of human-review feedback from running V1 on real Apple-silicon
hardware. Executed as sequential sub-agent batches (coding → green
`precommit_checks` → spec-aware CR → commit), `make ci` stays green. Each batch
is one commit. Items marked **[TODO]** are intentionally deferred with an
in-code `// TODO`. Checked = landed.

Continues `phase_11_feedback.md` (Round 1, G1–G7).

---

## B1 — Meeting titles (data model + logic)
- [ ] **Bug:** a recording started from the upcoming **"Join"** button saved the
  event info to the meeting but the title stayed `"Recording"` even though the
  event had a title. Auto-title from the associated event was not applied.
- [ ] Add **`editedTitle: Bool`** to the `Meeting` model (additive schema,
  default `false`). Set `true` **only** when the user manually edits the title.
  It gates auto-swap: "can we replace the title with a better one?" → yes unless
  the user set it.
- [ ] Title rules:
  - Default title = **"Untitled Meeting"** (was "Recording").
  - On **calendar association** (auto at record-start *and* manual correction):
    set title = event's title **unless `editedTitle == true`**.
  - On **manual edit**: set the title and set `editedTitle = true`.

## B2 — Association visibility + Meeting Detail UI
- [ ] **Bug:** linking a past meeting to a calendar event has **no visible
  impact for new links** (one older link shows fine). Diagnose why the calendar
  context block doesn't render/refresh for freshly-created associations; fix.
- [ ] Give the event-info (calendar context) block a **calendar icon** on the left.
- [ ] **Remove the "Join" button on the Meeting Detail view** (this view is
  post-recording) → replace with **"Open in Calendar"** which launches the
  calendar event.
- [ ] Association-picker empty state (the dialog shown for an *old* meeting):
  - Reword "No upcoming calendar events" → **"No calendar events near this
    recording's time"** (it is not filtered to upcoming).
  - When **calendar permission is missing**, show a **different** string
    (prompt to grant access), not the empty-results string.

## B3 — Delete meeting
- [ ] Add a **Delete** affordance inside Meeting Detail. After a **confirmation**
  prompt, delete the data-model row **and** the recording files on disk.

## B4 — Sidebar list + upcoming-time accuracy
- [ ] Sidebar meeting-list rows: add **date and duration** on the second line.
- [ ] **Bug:** a meeting that ended ~2h ago still appears in the Upcoming list
  (menu bar + sidebar) and shows as **"now"**. Once a meeting is over, remove it
  from the upcoming list.
- [ ] **Bug:** countdown lag — a meeting 58m away shows "1h 4m". Refresh the
  relative times **every minute, aligned to the clock-minute boundary**, so the
  `2m → 1m → now` countdown is accurate (menu bar + sidebar).

## B5 — Menu bar (window + nav + record icon)
- [ ] **Bug:** "Open Biscotti" makes the Dock icon appear but **does not create a
  window** — user must click the Dock icon to actually get one. Make it open/show
  a real window.
- [ ] **Bug:** the upcoming/recent menu links only navigate **if a window was
  already opened** — they must work from a cold menu-bar-only state too.
- [ ] Give the **"Record" / "Stop recording"** line an **icon** (only that line),
  using the same two-state icons used elsewhere in the menu.

## B6 — Onboarding buttons (conditional)
- [ ] Replace the always-shown **"Skip" + "Continue"** pair with a **conditional
  single button**:
  - **Before** doing the step's action → only **"Skip"**.
  - **After** doing the action → only **"Continue"** (larger, primary blue).
  - Never both at once. Never "Skip" once the thing is done (can't undo). Never
    "Continue" before the action.

## B7 — Notifications (broken)
- [ ] **Bug:** notifications are entirely broken — **no authorization prompt
  appears, no log**. Diagnose (is `requestAuthorization` ever called? bundle/
  entitlement/registration issue?), wire up the request (onboarding + Settings
  per-permission button), and add diagnostics.

## B8 — Search (re-launch results)
- [ ] **Enter** in the search field (and/or re-focusing it) should **re-launch the
  search pane** with the current term. Repro: search X → open a meeting → there's
  no way back to results (focusing the field doesn't re-search, Enter doesn't,
  only editing the text does).
