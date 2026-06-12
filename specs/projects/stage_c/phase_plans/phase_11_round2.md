---
status: complete
---

# Phase 11 — Round 2 (second hardware pass)

> **Status:** all batches B1–B8 landed (commits 36772fd, 9c440a7, 692ff71,
> 035cf37, 27ea34d, fd75d0b, df0b7a9, + B8). Each shipped coding → green
> precommit_checks → spec-aware CR → commit. Awaiting the next hardware pass to
> verify the hardware-only behaviors (notification prompt, menu-bar window
> creation from cold state).

Second batch of human-review feedback from running V1 on real Apple-silicon
hardware. Executed as sequential sub-agent batches (coding → green
`precommit_checks` → spec-aware CR → commit), `make ci` stays green. Each batch
is one commit. Items marked **[TODO]** are intentionally deferred with an
in-code `// TODO`. Checked = landed.

Continues `phase_11_feedback.md` (Round 1, G1–G7).

---

## B1 — Meeting titles (data model + logic)
- [x] **Bug:** a recording started from the upcoming **"Join"** button saved the
  event info to the meeting but the title stayed `"Recording"` even though the
  event had a title. Auto-title from the associated event was not applied.
- [x] Add **`editedTitle: Bool`** to the `Meeting` model (additive schema,
  default `false`). Set `true` **only** when the user manually edits the title.
  It gates auto-swap: "can we replace the title with a better one?" → yes unless
  the user set it.
- [x] Title rules:
  - Default title = **"Untitled Meeting"** (was "Recording").
  - On **calendar association** (auto at record-start *and* manual correction):
    set title = event's title **unless `editedTitle == true`**.
  - On **manual edit**: set the title and set `editedTitle = true`.

## B2 — Association visibility + Meeting Detail UI
- [x] **Bug:** linking a past meeting to a calendar event has **no visible
  impact for new links** (one older link shows fine). Diagnose why the calendar
  context block doesn't render/refresh for freshly-created associations; fix.
- [x] Give the event-info (calendar context) block a **calendar icon** on the left.
- [x] **Remove the "Join" button on the Meeting Detail view** (this view is
  post-recording) → replace with **"Open in Calendar"** which launches the
  calendar event.
- [x] Association-picker empty state (the dialog shown for an *old* meeting):
  - Reword "No upcoming calendar events" → **"No calendar events near this
    recording's time"** (it is not filtered to upcoming).
  - When **calendar permission is missing**, show a **different** string
    (prompt to grant access), not the empty-results string.

## B3 — Delete meeting
- [x] Add a **Delete** affordance inside Meeting Detail. After a **confirmation**
  prompt, delete the data-model row **and** the recording files on disk.

## B4 — Sidebar list + upcoming-time accuracy
- [x] Sidebar meeting-list rows: add **date and duration** on the second line.
- [x] **Bug:** a meeting that ended ~2h ago still appears in the Upcoming list
  (menu bar + sidebar) and shows as **"now"**. Once a meeting is over, remove it
  from the upcoming list.
- [x] **Bug:** countdown lag — a meeting 58m away shows "1h 4m". Refresh the
  relative times **every minute, aligned to the clock-minute boundary**, so the
  `2m → 1m → now` countdown is accurate (menu bar + sidebar).

## B5 — Menu bar (window + nav + record icon)
- [x] **Bug:** "Open Biscotti" makes the Dock icon appear but **does not create a
  window** — user must click the Dock icon to actually get one. Make it open/show
  a real window.
- [x] **Bug:** the upcoming/recent menu links only navigate **if a window was
  already opened** — they must work from a cold menu-bar-only state too.
- [x] Give the **"Record" / "Stop recording"** line an **icon** (only that line),
  using the same two-state icons used elsewhere in the menu.

## B6 — Onboarding buttons (conditional)
- [x] Replace the always-shown **"Skip" + "Continue"** pair with a **conditional
  single button**:
  - **Before** doing the step's action → only **"Skip"**.
  - **After** doing the action → only **"Continue"** (larger, primary blue).
  - Never both at once. Never "Skip" once the thing is done (can't undo). Never
    "Continue" before the action.

## B7 — Notifications (broken)
- [x] **Bug:** notifications are entirely broken — **no authorization prompt
  appears, no log**. Diagnose (is `requestAuthorization` ever called? bundle/
  entitlement/registration issue?), wire up the request (onboarding + Settings
  per-permission button), and add diagnostics.

## B8 — Search (re-launch results)
- [x] **Enter** in the search field (and/or re-focusing it) should **re-launch the
  search pane** with the current term. Repro: search X → open a meeting → there's
  no way back to results (focusing the field doesn't re-search, Enter doesn't,
  only editing the text does).
