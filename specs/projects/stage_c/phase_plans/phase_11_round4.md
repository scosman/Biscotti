---
status: complete
---

# Phase 11 — Round 4 (fourth hardware pass)

> **Status:** complete. Single item (P1) — playback control shows the wrong
> audio length — landed in one commit (coding → green `precommit_checks` →
> spec-aware CR → commit; `make ci` green). Reviewer verdict CLEAN; the
> model-wins tests are non-vacuous (fail without the `syncPlaybackState` guard).
> Awaiting the next hardware pass to confirm the correct total now shows on the
> playback control. The two heavier alternatives (decode the stream / re-container
> to mp4·caf on stop) remain **P3** — not needed since data-model duration fixes it.
>
> Continues `phase_11_round3.md` (N1–N6).

---

## P1 — Playback control shows the wrong audio length (use data-model duration)

- [ ] **Bug:** the audio playback control shows a wrong total length. Recordings
  are stored as **ADTS AAC**, which has **no duration field** in the container
  header, so today the total comes from `AVAudioPlayer.duration` — a rough
  size/bitrate guess that is often very wrong (claims 2h for a 30-min file).
  - **Observed self-correction:** `AVAudioPlayer.duration` refines toward the
    true value once the stream is decoded near the real end (scrubbing to ~1.5h
    on a 30-min file snaps the total to correct). This is emergent
    `AVAudioPlayer` behavior, re-read every tick by `syncPlaybackState()`.

- **Chosen approach (user's preferred "alternative, prob best"):** use the
  **`recordingDuration` already stored on the `Meeting` data model** (wall-clock
  elapsed captured at record-stop, in seconds) as the player's displayed total.

- **Design note — must be authoritative, not merely "initial":**
  `syncPlaybackState()` unconditionally overwrites `playbackDuration` with
  `audioPlayer?.duration` every 250 ms tick. A literal "init then let decode
  correct it" would therefore snap back to the bad guess the instant playback
  starts. So when the model duration is present (> 0) it is treated as the
  **stable, authoritative** total; the player-derived guess (+ its decode-time
  self-correction) remains the **fallback** only for older recordings that have
  no stored `recordingDuration` (nil/0). This achieves the user's goal — show the
  *right* length — and keeps the decode-correction safety net for legacy files.

- **No schema change:** `Meeting.recordingDuration: TimeInterval?` already exists
  (added earlier for the sidebar second line). This round only threads it into
  the detail read-model and the playback view-model.

- **Do NOT reuse `MeetingDetailData.duration`:** that field is the *calendar
  window* duration (`endDate − startDate`), not the recording's wall-clock
  duration. A new, separate `recordingDuration` field is added to the detail DTO.

- **The other alternatives (decode the stream / re-container to mp4·caf on stop)
  are P3** per the user — only needed if the data-model-duration approach doesn't
  fix the player. It does, so they are not implemented here.

### Change set
- [ ] `DataStore+ReadModels.swift`: add `recordingDuration: TimeInterval?` to
  `MeetingDetailData`; populate from `meeting.recordingDuration` in
  `meetingDetail(id:)`. Leave the existing calendar-window `duration` untouched.
- [ ] `MeetingDetailViewModel.swift` `syncPlaybackState()`: prefer
  `detail?.recordingDuration` when `> 0`, else `audioPlayer?.duration ?? 0`.
  (`loadAudioPlayer()` already calls `syncPlaybackState()`, so the initial value
  is covered without extra state.)
- [ ] `MeetingDetailView.swift`: resolve the `TODO(playback-duration)` comment
  (replace with an honest note: model-duration-first, guess as legacy fallback).
- [ ] Tests (non-vacuous — the B2 lesson): the model-present test sets the fake
  player's duration to a **different** (wrong) value and asserts that after
  `load()` **and a sync tick** `playbackDuration` equals `recordingDuration`
  (proves the model wins and is not clobbered); the fallback test leaves
  `recordingDuration` nil and asserts `playbackDuration` equals the fake player's
  value. Cover single-file (`MeetingDetailPhase8Tests`) and dual-file
  (`MeetingDetailDualPlaybackTests`); extend `CoreFixture.createMeetingWithAudio`
  to set `recordingDuration`; add a read-model mapping test for the new field.
