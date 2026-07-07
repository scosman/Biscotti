---
status: complete
---

# Stage B — MVP: Record → Transcribe App

The first **runnable, shippable** Biscotti app. It productionizes nothing new at the engine
level — it **integrates** the three Stage-A foundation libraries (`AudioCapture`,
`Transcription`, `DataStore`) into a real app the user can open and use end to end:

> **Start recording a meeting → stop → get a diarized transcript, stored and viewable.**

This is the build of **Project 4** from the repo roadmap ([`implementation_plan.md`](../../implementation_plan.md) → "Stage B — First runnable app"). The static topology and component homes are already fixed in [`architecture.md`](../../architecture.md); this project builds the **first thin slices** of those components and the app target that composes them.

## What it does (V1 / MVP)

- A **window-only** macOS app (sidebar + main area). Tap **Record** → it captures mic + system
  audio to disk. Tap **Stop** → the recording is saved and transcription runs **automatically**;
  the diarized transcript appears on the meeting's detail screen when ready.
- Past recordings are listed; clicking one opens its detail (transcript + metadata). A meeting
  can be **re-transcribed** on demand.
- Everything is on-device and local. Crash-safe recording (the Stage-A capture engine already
  streams crash-safe ADTS-AAC); a meeting record is created on Record and linked to its audio
  files as streaming begins, so a crash never orphans a recording.

## Deliberately OUT of scope (this is a real MVP)

Per the roadmap and the user's scope call, the MVP intentionally drops:

- **No menu bar / tray app** (no `MenuBarUI`). Window only.
- **No onboarding wizard** (no `OnboardingUI`). First-run setup is handled **just-in-time/inline**.
- **No calendar / EventKit**, **no meeting auto-detection**, **no notifications**, **no home
  screen**, **no search**, **no settings screen**, **no custom-vocabulary UI**, **no background/
  accessory operation**. These are later projects (Stage C+).

Anything that is a deliberate MVP shortcut we expect to revisit before a real ship is marked in
code with a `// TODO` comment so it's easy to find and clean up later.

## First-run setup (inline, no wizard)

- **Permissions** (microphone + system audio) are requested **just-in-time** the first time the
  user taps Record, with inline denial-recovery guidance if refused.
- **Model download** (the 1–3 GB WhisperKit + SpeakerKit models) happens **automatically** the
  first time a transcript is needed, with progress surfaced on the Meeting Detail screen.

## Components built (first slices)

Thin `Biscotti` app target (composition root + the embedded `BiscottiTranscriber.xpc` service);
`AppShellUI` (window + sidebar + routing); `RecordingUI` (active-recording screen);
`MeetingDetailUI` (transcript + metadata + re-transcribe); `MeetingListUI` (past-meetings list);
`Recording` module (session lifecycle over `AudioCapture`, owns storage paths, create+link record
on start, persist into `DataStore`, recover orphaned recordings on launch); `TranscriptionService`
module (hand audio paths to the engine → persist a transcript version → surface status →
re-transcribe); `Permissions` module (mic + system-audio, denial recovery); minimal
`DesignSystem`.

## Constraints

- Apple Silicon, macOS 15+. Swift-package-first: all logic/view-models/most views live in
  `BiscottiKit` modules and run under `swift test`; the app target stays thin (Apple glue only)
  and is the only thing needing `xcodebuild`.
- Bundle ID stays `net.scosman.biscotti`; ad-hoc signing (real notarization is Project 9).
- **Risk:** medium — first real integration of permissions + capture→file→transcript→store→UI.
