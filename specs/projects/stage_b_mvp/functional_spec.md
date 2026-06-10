---
status: complete
---

# Functional Spec: Stage B — MVP (Record → Transcribe App)

This is **Project 4** from the roadmap — the first runnable, shippable Biscotti app. It is a
**feature/integration** project: it adds almost no new low-level capability and instead **wires the
three Stage-A foundation libraries into a real app**.

This document specifies **what** the MVP must do and the contracts between the new app-level
components. Concrete API shapes (types, signatures) live in [`architecture.md`](architecture.md)
(and in `components/*.md` where a module needs more depth). The static topology — which component
lives where, its boundaries, its dependency edges — is already fixed by the repo
[`architecture.md`](../../../architecture.md) and is **not** re-litigated here. The screen/navigation
design lives in [`ui_design.md`](ui_design.md).

**Grounding — consume, don't re-derive:**
- The engines are done and validated. Their public APIs are fixed:
  `AudioCapture.AudioRecorder` (single-use, two-stream ADTS-AAC, `start(paths:)`/`stop()`),
  `Transcription.Transcriber` (`.hosted` XPC actor: `ensureModelsDownloaded`, `processAudio`,
  `statusStream`, `clearCache`), and `DataStore` (an `actor` over SwiftData with `createMeeting`,
  `attachAudio`, `addTranscript`, `setPreferredTranscript`, `recentMeetings`, `meeting(id:)`, …).
- The XPC service `XPCServices/BiscottiTranscriber` already exists and is wired into `ManualTestApp`.
  This project replicates that wiring into the **main app target** (`App/project.yml`).
- Permissions approach: [`research/permissions`](../../../research/permissions/README.md) — Core-Audio
  taps (`kTCCServiceAudioCapture`, the "System Audio Recording" pane) + mic
  (`AVCaptureDevice` / `kTCCServiceMicrophone`); system-audio has **no public status API**, so denial
  is inferred from all-zero buffers (the engine already exposes `probableSystemAudioDenied()`).

---

## 0. The defining constraint — autonomy until a final hardware phase

Mirroring Stage A: this build is ordered so **every phase except the last is completable by an
agent with no human and no hardware** — it builds and passes unit/integration tests through
`hooks-mcp` (`build`, `test`, `lint`, and `build_app` where the app bundle is involved). Tests use
stubs/seams (a fake capture engine, a fake transcription engine, an in-memory `DataStore`) and never
touch a live mic, live system audio, a real CoreML download, or a real TCC prompt.

**All hardware/system/human validation is deferred to a single final phase** ("run the app on real
hardware"): real two-stream capture, the real permission dialogs, the real model download/compile,
the real XPC crash-isolation, and "is the transcript actually good." A correct MVP reaches that phase
**fully green on automated checks**, with the app launching and the headless flow proven by tests.

---

## 1. The MVP flow (end to end)

The single user journey the MVP must deliver, and the system behavior at each step:

1. **Open the app.** A window opens (sidebar + main area). No window is required for prior state;
   on launch the app **recovers any orphaned recording** from a previous crash (see §6) and lists
   past meetings.
2. **Tap Record.** First time only: the app requests **microphone** and **system-audio** permission
   just-in-time (§5). On grant, a new **Meeting** record is created immediately (untitled,
   auto-named — see §2), a fresh `AudioRecorder` starts capturing mic + system to two ADTS-AAC files
   in a known cache location, and the two `AudioFileRef`s are linked to the meeting **as streaming
   begins** (so a crash can never orphan it). The UI switches to the **Recording** screen showing
   elapsed time and a Stop control.
3. **Tap Stop.** Capture stops and the files finalize. Transcription is **queued automatically**
   (§4). The UI routes to the **Meeting Detail** screen for this meeting.
4. **Transcription runs.** If models aren't present, they download first (progress shown inline on
   Meeting Detail; §4/§5). The diarized transcript is produced by the XPC worker, **persisted as a
   new transcript version**, and set as the meeting's preferred version. Meeting Detail renders the
   diarized transcript (speaker-labeled segments) with metadata (title, date, duration).
5. **Browse & revisit.** The sidebar's past list shows the meeting; selecting any past meeting opens
   its detail. **Re-transcribe** is available on demand (re-runs from the stored mic+system files,
   adds another version, promotes it).

Everything is local and on-device. The app never blocks the main thread on capture or transcription.

---

## 2. Recording session lifecycle (`Recording` module)

**Purpose.** The app-level recording lifecycle on top of the `AudioCapture` engine. Owns storage
locations and the data-model wiring; the engine owns the bytes.

**Features & behaviors:**

- **Storage locations (it owns them).** Recordings are written under a stable, app-owned directory
  (Application Support, e.g. `…/Application Support/Biscotti/Recordings/<meetingID>/{mic,system}.aac`)
  — **not** a temp dir, so crash-recovered files survive. The module derives the `CapturePaths` and
  hands them to the engine; the engine never chooses paths.
- **Create + link on start (crash-safety contract).** On `start`, the module: (a) creates the
  `Meeting` in `DataStore`; (b) computes paths and creates the recording directory; (c) attaches two
  `AudioFileRef`s (mic + system, with the real paths) to the meeting **before/at** the moment
  capture begins — never after stop. This makes the "audio model created on start, linked as
  streaming begins" requirement real (per `app_overview.md` → Misc App Reqs).
- **Auto-naming.** New meetings get a sensible default title (e.g. `"Recording — Jun 9, 2:30 PM"`).
  Renaming is a later project; the MVP just needs a non-empty title. `// TODO` mark as a pre-ship
  nicety if hardcoded formatting needs localization.
- **Single-use engine discipline.** `AudioRecorder` is single-use (reuse throws `recorderConsumed`).
  The module creates a fresh recorder per session and discards it on stop. Two concurrent recordings
  are **not** supported in the MVP (Record is disabled/no-op while already recording).
- **Live state for UI.** Expose an observable recording state — `isRecording`, elapsed time, and the
  current meeting id — driven off the engine's `stateStream()` (which already emits ~every 250 ms).
  (`micLevel`/`systemLevel` are currently hardcoded to 0 in the engine; the UI must not depend on
  real meters — show elapsed time, not a live VU. `// TODO` revisit levels when the engine wires RMS.)
- **Stop & finalize.** On `stop`, await the engine's stop (idempotent), mark audio presence/sizes in
  the store (`markAudioPresence`), and hand the meeting id to the transcription queue (§4).
- **Orphan recovery on launch** (§6).
- **Permission gating.** Recording must not start if mic/system permission is missing; it asks
  `Permissions` (§5) and surfaces a recoverable error rather than producing a silent/empty file.

**Contracts:**
- **In:** a request to start (no args) / stop; the `DataStore` and a capture-engine factory injected.
- **Out:** an observable recording state; the created meeting id; on stop, a signal to enqueue
  transcription. Errors are typed and surfaced (never swallowed).

**Edge cases:**
- Start tapped twice → second tap is a no-op while recording.
- Engine `start` throws (mic denied, tap creation failed) → the just-created meeting is either
  cleaned up or left with `isPresent=false` audio refs and surfaced as a failed recording; the UI
  shows the error and returns to a recordable state. (Design decides which; must not crash.)
- Stop with no active recorder → no-op.
- Disk write error mid-recording (`lastSystemWriteError`) → surfaced as a warning on the meeting.

---

## 3. Permissions (`Permissions` module)

**Purpose.** A unified, testable view of the system permissions the MVP needs: **microphone** and
**system audio**. (Calendar is a later project and is out of scope here.)

**Features & behaviors:**

- **Microphone:** status via `AVCaptureDevice.authorizationStatus(for: .audio)`; request via
  `requestAccess`. Full public API.
- **System audio:** **no public status API** (per research). The MVP does **not** add the private
  TCC probe. Strategy: trigger the prompt by exercising the engine's
  `requestPermissions(systemProbePath:)` on first Record, then **infer denial** post-start from the
  engine's `probableSystemAudioDenied()` / all-zero buffers, and surface inline recovery. `// TODO`
  the private-TCC preflight is a known nicety deferred past MVP.
- **Unified surface:** a `granted / denied / needsAction / notDetermined` view per permission for the
  UI to drive just-in-time requests and inline denial recovery.
- **Denial recovery:** provide deep links to the correct System Settings panes
  (Microphone; "Screen & System Audio Recording") via `x-apple.systempreferences:` URLs, plus copy
  explaining the fix. Re-requesting after denial is a no-op on macOS — the UI guides the user to
  Settings.

**Contracts:**
- **In:** which permission to check/request. System calls live behind a seam (a protocol) so the
  state machine unit-tests without real TCC.
- **Out:** per-permission status; a request operation that triggers the prompt; settings-pane URLs.

**Edge cases:** denied-then-fixed-in-Settings (status refresh on app focus); not-determined vs denied
distinction for mic; system-audio "granted but silent" (route/other issue) vs "denied" ambiguity —
surfaced as a warning, not a hard failure.

---

## 4. Transcription orchestration (`TranscriptionService` module)

**Purpose.** The app-facing orchestration of the `Transcription` engine: run jobs, surface status,
persist results, re-transcribe. The engine owns the ML and the merge; this module owns the app glue.

**Features & behaviors:**

- **Auto-run on stop.** When a recording stops, the service enqueues a transcription job for that
  meeting (mic + system file paths from the meeting's `AudioFileRef`s).
- **Model readiness.** Before the first job (or when status is `needsDownload`), call
  `ensureModelsDownloaded(status:)`; surface download/compile/loading/running status to the UI via an
  observable that the Meeting Detail screen renders. (Note: the engine's `Transcriber.statusStream()`
  emits a simplified view — `downloading/running/ready/error`; the service maps these to UI states.
  `// TODO` richer compiling/loading granularity if needed.)
- **Run + persist.** Call `processAudio(mic:system:customVocabulary:)`. On success, persist via
  `DataStore.addTranscript(_:vocabularyUsed:mappedEventIdentifier:to:)` (vocabulary is empty `[]` in
  the MVP — no vocab UI; `mappedEventIdentifier` is `nil` — no calendar), then
  `setPreferredTranscript` to promote it. Surface completion to the UI.
- **Re-transcribe on demand.** Re-run from the same stored files, append another version, promote it.
  This is the same path as auto-run, triggered manually.
- **Single in-flight job (MVP).** One job at a time is sufficient; if a second is requested, queue or
  reject cleanly. Concurrent multi-job scheduling is a later concern. `// TODO`.
- **Crash isolation.** Worker crashes surface as the engine's retriable `workerInterrupted` error;
  the service exposes a retry and a clear failed-state, never a hung UI.

**Contracts:**
- **In:** a meeting id (resolves to mic+system paths via `DataStore`); the engine client + store
  injected (engine behind a `TranscriptionEngine`-style seam for tests).
- **Out:** an observable per-job/model status; a persisted transcript version + promotion; typed
  errors surfaced.

**Edge cases:** offline on first download → `needsDownload`/download-failed, retriable, no silent
hang; insufficient disk → typed error surfaced; audio file missing (`isPresent=false`) → clear error,
no crash; transcript with 0 segments / 1 speaker → rendered as-is (valid).

---

## 5. First-run setup (inline, no wizard)

There is **no `OnboardingUI`**. Setup is folded into the normal flow:

- **Permissions** are requested **just-in-time on first Record** (§3). Denial shows inline recovery
  on the Recording entry point, and the app returns to a recordable state once fixed.
- **Model download** happens **automatically when the first transcript is needed** (§4), with
  progress and disk-check surfaced **on the Meeting Detail screen** (the transcript area shows
  "Downloading model… / Preparing… / Transcribing…" states). No separate setup screen.
- Both are deliberate MVP shortcuts; the eventual `OnboardingUI` (a later project) will front-load
  them. Mark inline-only assumptions with `// TODO`.

---

## 6. Crash-safety & orphan recovery (cross-cutting)

- **Crash-safe bytes:** already guaranteed by the engine (ADTS-AAC, self-syncing, no finalization).
- **Never orphaned:** because the meeting + audio refs are created at start (§2), a crash mid-record
  leaves a `Meeting` whose audio files exist on disk and are linked.
- **Recovery on launch (`Recording`):** scan for meetings that were recording (e.g. have audio refs
  but were never finalized / have no transcript and a non-finalized marker) and reconcile: mark audio
  presence/sizes, leave them as completed-but-not-transcribed recordings the user can transcribe.
  Exact "in-progress" marker is a design detail (a transient flag cleared on clean stop, or
  presence-based reconciliation). Must be deterministic and unit-testable with a seam over the file
  system / store. `// TODO` note any simplification.

---

## 7. UI behavior (see `ui_design.md` for layout)

- **AppShellUI** — the window: a sidebar (a Record affordance + a recording indicator + a past-
  meetings list) and a main content area that routes between **Recording** and **Meeting Detail**.
  Selecting a past meeting routes to its detail. No Home, no Search, no Settings in the MVP.
- **RecordingUI** — active-recording screen: elapsed time, the current meeting title, a prominent
  **Stop**. Driven by `Recording`'s observable state.
- **MeetingDetailUI** — transcript + metadata (title, date, duration); the inline model-download /
  transcription status; the diarized transcript (speaker-labeled segments, in time order); a
  **Re-transcribe** action; a denial/error banner area. Version switching may be minimal in the MVP
  (always show preferred) — `// TODO` full version picker is Project 7.
- **MeetingListUI** — the sidebar/past list slice: a scrollable list of past meetings (title + date),
  selecting routes to detail.
- **DesignSystem (minimal)** — shared colors/typography/spacing and a few primitives (e.g. a record
  button, a status row, a transcript-segment row), kept "tight, Apple-native." Just enough for these
  screens.

All view models live in `BiscottiKit` modules and unit-test headlessly; views are previewable.

---

## 8. App target & XPC glue (`Biscotti` app + `BiscottiTranscriber.xpc`)

- **Composition root:** instantiate the on-disk `DataStore`, the `Permissions`, `Recording`,
  `TranscriptionService` services, and the `AppCore`-lite coordinator (MVP may keep a thin
  coordinator object rather than the full `AppCore` module — see architecture), then present the
  `AppShellUI` window scene. Window-only: standard `WindowGroup`, regular (dock) activation, **no**
  `MenuBarExtra`.
- **XPC wiring (replicate `ManualTestApp`):** add the `Transcription` package + the
  `BiscottiTranscriber` xpc-service target to `App/project.yml`, embed it in the app, so the app's
  `Transcriber(backend: .hosted(serviceName: "net.scosman.biscotti.BiscottiTranscriber"))` resolves.
- **Entitlements & Info.plist:** `com.apple.security.device.audio-input` (covers mic + system audio);
  `NSMicrophoneUsageDescription` + `NSAudioCaptureUsageDescription`; non-sandboxed; ad-hoc signed.
- **Attribution `// TODO`:** argmax-oss-swift / model licenses must be surfaced before ship — mark it.

---

## 9. Testing strategy

- **Unit/integration (gating, hardware-free):**
  - `Recording` with a **fake capture engine** + in-memory `DataStore`: start creates meeting + links
    refs; stop finalizes + enqueues; orphan recovery reconciles; double-start no-ops; error paths.
  - `TranscriptionService` with a **fake `TranscriptionEngine`** + in-memory store: status mapping;
    persist-and-promote; re-transcribe adds a version; error/retry; offline/disk/missing-file.
  - `Permissions` state machine behind a seam: status transitions, denied-recovery URLs.
  - UI **view models** headlessly: routing/selection, recording-state rendering, transcript rendering,
    download/transcribe status rendering.
- **App tier (non-gating):** `build_app` (the app + embedded XPC compile/link/launch).
- **Manual/hardware (final phase, human):** the real Record→Stop→Transcribe loop, the real prompts,
  the real model download, two-stream quality, crash-isolation. Optionally extend `ManualTestApp` or
  validate directly in the new app. Not gating.

---

## 10. Out of scope (explicit)

No calendar/EventKit · no meeting auto-detection · no notifications · no menu-bar/tray · no Home ·
no Search · no Settings screen · no custom-vocabulary UI · no onboarding wizard · no background/
accessory operation · no audio playback in Meeting Detail (transcript + metadata only — `// TODO`
playback is Project 7) · no Developer-ID signing/notarization (Project 9). Each is a defined later
project; none requires re-topology.
