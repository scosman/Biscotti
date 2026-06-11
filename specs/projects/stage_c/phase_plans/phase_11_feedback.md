---
status: in-progress
---

# Phase 11 — Human review feedback (hardware pass)

User feedback from running the feature-complete V1 on real Apple-silicon hardware. Implemented in grouped sub-agent passes (coding → CR → commit), keeping `make ci` green. Items marked **[TODO]** are intentionally deferred with an in-code `// TODO`. Checked = landed.

Also pending from the decisions review: **architecture.md reconcile** — document that conference detection lives in the `MeetingCatalog` (L0) module rather than the RemoteConfig/Calendar split the doc still describes (do at start of Phase 11 coding).

---

## G1 — Onboarding
- [ ] Remove the per-permission action button once granted (Microphone, System Audio, Calendar) — show granted state instead.
- [ ] Layout: title higher; content centered in remaining space; **taller steps (e.g. Choose Calendars) must not scroll until they actually overflow** — currently cropped to a small central scroll area.
- [ ] Rename "Download speech model" → **"Download Local AI Models"**.
- [ ] Notification-access step doesn't work — **[TODO]** acceptable to mark with a TODO for now.
- [ ] Add a **"Launch at Login?"** step — "Start Biscotti when you start your computer?" with **[No] [Yes]** (no skip/continue). Wire to existing `setLaunchAtLogin`.

## G2 — Settings
- [ ] **Remove "Custom Vocabulary"** entirely (re-add when implemented; no premature stub). *(Supersedes earlier review decision #3 "hide".)*
- [ ] **Remove "Re-run onboarding".**
- [ ] Reorder: **Permissions above Calendars; Calendars last.**
- [ ] **Permissions: add a request/grant button** next to each permission's status line when NOT authorized — same position as the existing "Open System Settings" button. Settings should be able to REQUEST access directly (mic, system audio, calendar, notifications), not just deep-link. (Removing "Re-run onboarding" is fine because these per-permission buttons replace its purpose.)
- [ ] **Bug: Settings shows stale/wrong permission status** — e.g. calendar was approved from Home and works, but Settings shows "Not requested". Settings must read/refresh LIVE permission status on load (call the Permissions refresh / read the real authorization status), and reflect changes.

## G3 — Meeting Detail
- [ ] **Editable title** — inline editing; Enter saves; no save button.
- [ ] **Auto-titles must not include the date** — date is metadata we always save + show; embedding it in the title causes doubles. (Find the auto-title generator; strip date; ensure date shown from metadata.)
- [ ] **Linked calendar event**: either association isn't persisting or there's no visual showing the linked event info (likely the latter). Investigate; show the linked event's details.
- [ ] **Hide** the "Calendar event changed. Re-transcribe with updated vocabulary?" prompt — **[TODO]** bring back once vocab support lands (doesn't make sense without vocab).
- [ ] Remove the **"Join"** button for meetings that ended **>30 min ago**.
- [ ] Playback bar: **[TODO]** total audio time is incorrect — our AAC (ADTS) files have no duration in the container header; need to process the files to compute duration.
- [ ] Playback: currently seems to play only `mic.aac` — must play **both `mic.aac` + `system.aac`, synced** (so remote participants are audible).

## G4 — Search
- [ ] Clicking anything in the search page should **unfocus the search field**.
- [ ] Search must include the **Notes** field — **same weight as transcript**.
- [ ] On edit: **clear existing results immediately** when the query becomes invalid/changes and show the spinner (keep the debounce-before-search, but don't show stale results during the wait).
- [ ] Fix the **"< Back"** button bug: first tap does nothing; second returns Home instead of the actual previous page (was on a meeting/recording page).
- [ ] **[TODO]** Push navigation onto a real nav stack so "Back" returns into search results (see effort note in the handoff message; likely its own small follow-up).

## G5 — Upcoming / Event detail page
- [ ] Show **all available details**: attendees, notes, meeting URL, location, etc.
- [ ] For a future meeting (>15 min away): show an **"Open Link"** button (opens the conference URL).
- [ ] Within **±15 min** of the scheduled time: show a **"Join and Record"** button.
- [ ] Display platform names properly — **"Meet" → "Google Meet"** (fix MeetingCatalog display names).

## G6 — App lifecycle / Menu bar / Dock
- [ ] **MenuBarExtra: switch from `.window` back to the simpler `.menu`** style for a native feel.
- [ ] Menu-bar items should navigate: **upcoming items → event page, recent items → meeting page**.
- [ ] **Remove "See All"** until a dedicated page exists.
- [ ] **"Open Biscotti"** should bring the window to front if backgrounded, or open it if closed (match Dock-click behavior).
- [ ] Bug: **closing and reopening the window wipes the content panel** (meetings/recordings disappear) — fix the window/scene/AppCore lifecycle so state persists.
- [ ] **Dock icon should disappear when the window is closed** (menu-bar-only), and reappear when a window opens — activation-policy switch (`.accessory` ↔ `.regular`). *(Refines C7.)*

## G7 — Docs
- [ ] Reconcile `architecture.md`: conference detection lives in `MeetingCatalog` (L0), not the RemoteConfig/Calendar split the doc describes.
