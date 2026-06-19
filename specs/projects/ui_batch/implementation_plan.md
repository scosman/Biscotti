---
status: complete
---

# Implementation Plan: UI Batch

One phase per item, built autonomously. Each phase ends green on `lint`+`test` (and `build_app` where app/UI glue changed) via `hooks-mcp`, with its **own commit(s)** for rollback granularity. Phases bundling two independent sub-fixes produce **two commits**. See `functional_spec.md` (behavior) and `architecture.md` (where/how) for details.

## Phases

- [x] **Phase 1 — Record button size.** Idle top-right Record button one Apple control-size step taller/bigger; near-equal height to the recording-state button. _(1 commit)_ — spec §1.

- [x] **Phase 2 — Reduce "RECORDING" emphasis.** _(2 commits)_ — spec §2.
  - 2a: Normalize the sidebar `RecordingNowSection` to a standard sidebar row (drop red backdrop/stroke; secondary-color subtitle).
  - 2b: Disable the top-right recording button while on the recording page (`isOnRecordingPage`), mirroring Home-on-Home.

- [x] **Phase 3 — "See All" as the list's last row.** Move "See All" from the header into the bottom row of the home Past-Meetings card: left-labeled, grey total count before the chevron; hidden when there are no past meetings. _(1 commit)_ — spec §3.

- [x] **Phase 4 — Play links start playback.** Transcript timestamp links and notes `biscotti://…` deep-links seek **and** start playing if paused (via `seekAndPlay`); already-playing keeps playing. _(1 commit)_ — spec §4.

- [ ] **Phase 5 — Transcribing UI.** _(2 commits)_ — spec §5.
  - 5a: Don't show the "Downloading…model" phase on a cache hit — simple delay-gate (~5s) or real-signal-gate; plain "Transcribing…" otherwise. **Research the open question** (is the readiness/download check itself slow on a cache hit? consider an optimistic "assume cached → detect failure → download" flow) and report at review. **Touches `Packages/Transcription` → mark `tx_*` manual tests `not-run`.**
  - 5b: Centered transcribing layout — bigger spinner, larger centered text, subtitle on its own centered line (no horizontal shift).

- [ ] **Phase 6 — Global ⌘⇧R + settings toggle.** In-repo Carbon `RegisterEventHotKey` wrapper starts a recording OS-wide; `AppSettings.globalRecordShortcutEnabled` (default ON) toggle in Settings registers/unregisters live; no new dependency, no extra permission. _(1 commit)_ — spec §6.

- [ ] **Phase 7 — Multi-select + delete.** _(2 commits)_ — spec §7.
  - 7a: Migrate `meetingsSelection` `UUID?` → `Set<UUID>` (shift/⌘ multi-select); detail pane shows "N meetings selected" placeholder (ContentUnavailableView-style, with a Delete button) when >1 selected.
  - 7b: Delete key (and placeholder Delete button) → confirmation alert (singular/plural) → multi-delete; empty selection no-ops; existing detail-menu single delete unchanged.

- [ ] **Phase 8 — Human review & sign-off.** Walk the user through each item (ideally running the app), gather feedback, and make tweak commits per item as needed. No new scope — polish/sign-off only.
