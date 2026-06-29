---
status: complete
---

# Functional Spec: Model Download UX

## 1. Purpose & Goals

Improve the user experience around AI model downloads on both the **Settings** and
**Onboarding** surfaces, for both model kinds:

- **LLM** (language model) — `Packages/LocalLLM`, downloaded by `ModelDownloader` →
  surfaced through `Intelligence/ModelManager` and the `ManageModelsSheet`
  (Settings) and `ModelCard` (Onboarding).
- **Transcription** (WhisperKit speech-to-text + SpeakerKit speaker-ID, "ArgMax")
  — `Packages/Transcription`, downloaded inside the SDK via
  `InProcessTranscriptionEngine` → surfaced through `TranscriptionService` and the
  onboarding `ModelCard`.

Three concrete improvements:

1. **Cancel an in-flight LLM download** — stop it and delete the partial file.
2. **Cancel an in-flight transcription download (best-effort)** — same intent;
   cancel the work and delete partial files even if the SDK doesn't natively
   support cancellation.
3. **Pre-flight disk-space check before any download** — if there isn't enough
   free space, warn the user in a modal and don't start the download.

All three apply to **both** Settings and Onboarding.

## 2. Scope

**In scope**

- Cancel affordance + cancel logic for LLM downloads (Settings + Onboarding).
- Cancel affordance + best-effort cancel logic for transcription downloads
  (Onboarding; Settings does not currently expose a transcription download — see
  §6.3).
- Click-time disk-space check + warning modal for every model download, both kinds,
  both surfaces.
- Reconciling the existing fragmented disk checks into one consistent rule.

**Out of scope**

- Download **resume** after cancel/failure (still restart-from-scratch).
- Checksum / integrity verification (tracked separately for Project 10).
- A unified cross-kind "download manager" UI. The two model kinds keep their
  existing separate presentation; we only add cancel + disk-check to each.
- Background/queued downloads, pause (distinct from cancel), or scheduling.
- Changing *which* models exist, their sizes, or selection logic.
- Adding a transcription-model management UI to Settings (it isn't there today;
  this project doesn't add it).

## 3. Feature: Cancel LLM Download

### 3.1 Behavior

- While an LLM model is in the `.downloading` state, a **Cancel** control is shown
  next to its progress, on every surface that renders that download.
- Activating Cancel:
  1. Stops the in-flight download immediately.
  2. Deletes the partial file on disk (the `.partial` temp file).
  3. Returns the model to the **not-downloaded / idle** state (not a *failed*
     state). The row reverts to showing a "Download" affordance.
- No confirmation dialog — cancel is immediately reversible (the user can just
  download again), and a partial download has no value to protect.

### 3.2 Correctness requirements

- **Cancel must land in `.notDownloaded`, not `.failed`.** Today,
  `ModelManager.downloadModel` distinguishes `catch is CancellationError`
  (→ `.notDownloaded`) from any other error (→ `.failed`). But a cancelled
  `URLSessionDataTask` surfaces as `NSURLErrorCancelled`, which
  `ModelDownloader.download` currently wraps into `LocalLLMError.downloadFailed`.
  As written, a user cancel would therefore render as a **download failure**.
  The implementation must ensure a user-initiated cancellation is recognized as a
  cancellation end-to-end (e.g. `ModelDownloader` maps `URLError.cancelled` /
  `NSURLErrorCancelled` to `CancellationError`, or `ModelManager` treats that code
  as a cancel) so the row shows the clean idle state.
- **Partial file is always removed on cancel.** `ModelDownloader.download`'s
  `catch` already deletes the `.partial` temp file on any thrown error; this path
  must remain correct for the cancel case. The final model file is only ever
  created by an atomic move on success, so a cancel can never leave a usable-looking
  partial at the final path.
- **The cancel target must be reachable.** `ModelManager.downloadModel` is started
  today as a non-retained `Task { … }`, so there is nothing to call `.cancel()` on.
  The download Task must be retained (keyed by model id) so a `cancelDownload(id:)`
  can cancel it. The retained Task must be cleared when the download finishes,
  fails, or is cancelled.

### 3.3 Edge cases

- **Cancel races completion.** If the user taps Cancel in the instant the download
  finishes, the result is whichever the system observes first: a completed download
  remains downloaded; an effective cancel reverts to idle and removes the partial.
  No corrupted/half state is acceptable.
- **One-at-a-time guard.** LLM downloads are one-at-a-time
  (`ModelManager.canStartDownload`). After a cancel fully settles (Task cleared,
  state back to idle), a new download — of the same or another model — must be
  startable.
- **Cancel while the app is quitting.** Out of scope to specially handle; an
  interrupted download already leaves only a `.partial` that is ignored/overwritten
  on next attempt.

## 4. Feature: Cancel Transcription Download (Best-Effort)

The transcription download runs inside the WhisperKit/SpeakerKit SDK
(`try await WhisperKit(config)` / `try await SpeakerKit(config)`), which does not
expose an explicit cancel API. We provide a **best-effort** cancel.

### 4.1 Mechanism (resolved in architecture)

The real app runs the transcription download **in the `BiscottiTranscriber.xpc`
worker process** (`.hosted` backend). The reliable way to stop it is therefore not
Swift `Task` cancellation (which only abandons the app's await of the XPC reply while
the worker keeps downloading) but **tearing down the XPC connection** — invalidating
it makes launchd terminate the worker, and the worker's in-flight download dies with
the process. We then delete any partial files. See architecture §3 for the design.
This makes the "best-effort" cancel reliable in practice for the shipping app; the
hardware test (below) confirms it. (For the in-process backend used only by the CLI/
tests, we fall back to Task cancellation + cache cleanup.)

### 4.2 Behavior

- While the transcription model is downloading, a **Cancel** control is shown next
  to its progress (the indeterminate "Downloading speech-to-text model…" status).
- Activating Cancel:
  1. Cancels the Swift Task driving `ensureModelsReady`.
  2. After the task unwinds (returns or throws), **deletes the transcription model
     directory** so no partial files remain
     (`~/Library/Application Support/Biscotti/models/argmaxinc/…`, i.e. both the
     `whisperkit-coreml` and `speakerkit-coreml` trees). Deleting the whole
     transcription model tree is acceptable because a partial download is unusable
     and a re-download is the recovery path.
  3. Returns the transcription row to the **idle / not-downloaded** state.

### 4.3 Correctness requirements & risks

- **Don't delete while the SDK may still be writing.** The cleanup delete must
  happen *after* the cancelled task has finished unwinding, not concurrently, to
  minimize the chance the SDK re-creates files after deletion. If the SDK ignores
  cancellation and runs to completion, we still treat the user's intent as
  "cancelled": the files are deleted and the row returns to idle.
- **Idempotent / safe delete.** Deleting the model directory must tolerate a missing
  directory and must not touch unrelated data (only the transcription model trees).
- **State reset.** The transcription status (`ModelStatus` / `TranscriptionService`
  job/model status) and onboarding flags (`isDownloading`, `downloadStatus`,
  `downloadComplete`, `downloadFailed`) must reset so the row is cleanly
  re-downloadable.
- **Hardware verification required.** Because cancellation propagation through the
  SDK can't be fully verified in unit tests, the manual-test pass on real hardware
  must confirm: (a) cancel returns control promptly, (b) no leftover partial model
  files, (c) a subsequent re-download succeeds. Per the repo's manual-test staleness
  rule, touching `Packages/Transcription` marks the `tx_*` manual tests `not-run`.

### 4.4 Edge cases

- **Cancel near completion.** If the model finishes downloading just as the user
  cancels, the cleanest observable outcome wins; we must not leave a partially
  deleted (corrupt) model tree. If completion wins, the model is present and ready;
  if cancel wins, the tree is removed and the row is idle.
- **Both models downloading at once (Onboarding).** Cancelling the transcription
  download must not affect an in-flight LLM download, and vice-versa. Cancels are
  independent per row.

## 5. Feature: Pre-Flight Disk-Space Check

### 5.1 Behavior

- The disk check runs **at the moment the user taps Download** (click-time), for
  every model download (LLM and transcription), on every surface.
- If there is **enough** free space, the download starts normally.
- If there is **not enough** free space, **no download starts**. Instead a simple
  modal alert appears:
  - Explains there isn't enough free disk space, states roughly how much is needed
    vs. available, and tells the user to free up space and try again.
  - Has a single **OK** button that dismisses the modal. Nothing else.
- There is **no** persistent "insufficient disk" inline state and **no** dedicated
  "Re-check" button. The user frees up space and taps **Download** again; the check
  simply re-runs at that next tap. (If space is now sufficient, the download
  proceeds; if not, the modal appears again.)

### 5.2 The space requirement rule (unified)

- Required free space = **model download size + 2 GB** buffer. The 2 GB is a
  deliberately generous, round buffer: it covers temp/extraction overhead *and* is
  sized to absorb a concurrently-started transcription download (which is < 2 GB —
  see §5.4), so the common Onboarding "start both downloads" case doesn't overrun
  the disk.
- Per kind:
  - **LLM**: download size = `LLMModel.approxDownloadBytes` for the targeted model.
  - **Transcription**: download size = the engine's existing estimated download
    bytes for the configured STT + speaker models (the value
    `InProcessTranscriptionEngine`/`DiskSpaceChecker` already computes), summed as
    appropriate.
- Available space = the volume's available capacity for important usage
  (`URLResourceValues.volumeAvailableCapacityForImportantUsageKey`) at the model
  cache location — the same API both existing checkers already use.
- This single rule replaces the three current, inconsistent checks (the hardcoded
  1500 MB onboarding check; `ModelSuitability.hasEnoughDisk`'s exact-size,
  no-buffer comparison; and the transcription engine's mid-download throw). The
  engine's mid-download throw may remain as a defensive backstop, but the
  click-time check is the primary, user-visible gate.

### 5.3 Relationship to the existing proactive states (a deliberate change)

Today the UI proactively **disables** the Download button and shows an inline
"insufficient disk" warning chip (`ModelChoice.blockedReason == .insufficientDisk`
in `ManageModelsSheet`; `ModelRowState.insufficientDisk` in onboarding `ModelCard`).
This project **replaces the disk-based proactive blocking with the click-time
modal**: the Download button stays enabled (for runnable models) and the disk
verdict is delivered as a modal on tap.

- **RAM-based blocking stays as-is.** A model the hardware can't run
  (`ModelBlockedReason.cannotRun`) remains proactively disabled/greyed — RAM is not
  something the user can "free up," so a click-time modal is the wrong pattern for
  it. Only the *disk* dimension moves to the click-time modal.

### 5.4 Edge cases

- **Concurrent downloads vs. one shared volume.** The check is per-model against
  currently-available space at tap time. In Onboarding the user can start the
  transcription and LLM downloads close together; each individually passes while
  their combined size may exceed free space. The **2 GB buffer (§5.2) is sized to
  cover this**: since a transcription download is < 2 GB, an LLM check that requires
  `llmSize + 2 GB` leaves room for a concurrent transcription download. We do not
  build exact cross-download space accounting; the buffer plus the per-download
  failure path (§7) cover it.
- **Download size unknown / model not in catalog.** If a model's size can't be
  resolved, the check does not falsely block (it errs toward allowing the download,
  matching today's `hasEnoughDisk` "nil free bytes ⇒ allow" stance), and the normal
  download error path handles any real out-of-space failure.
- **Space freed between taps.** Because the check is purely click-time, freeing
  space and tapping Download again is the entire remediation loop — no app restart
  or manual refresh required.

## 6. Surface-by-Surface Behavior

### 6.1 Settings — `ManageModelsSheet` (LLM only)

- Each downloading model row gains a **Cancel** control alongside its progress
  bar/percentage (today the `.downloading` primary action is `EmptyView()`).
- The **Download** button is no longer disabled for insufficient disk; tapping it
  runs the click-time disk check and either starts the download or shows the modal.
- The RAM-based `cannotRun` greying/disable is unchanged.
- The disk warning is presented as an alert/modal over the sheet.

### 6.2 Onboarding — `ModelCard` (transcription + LLM rows)

- The **language (LLM)** row gains a **Cancel** control in its downloading state
  (`DownloadControl` determinate branch); cancel behaves as §3.
- The **transcription** row gains a **Cancel** control in its downloading state
  (`DownloadControl` indeterminate branch); cancel behaves as §4 (best-effort).
- Both rows run the click-time disk check on their Download tap and show the modal
  on insufficient space.
- The existing `ModelRowState.insufficientDisk` proactive state is removed in favor
  of the click-time modal (§5.3). The onboarding footer logic ("Skip"/"Continue",
  "Downloads will continue in the background") is unchanged except that a cancelled
  download reverts "started" → not-started, so the footer recomputes accordingly
  (e.g. cancelling the only in-flight download can revert "Continue" back to "Skip").

### 6.3 Settings — transcription

Settings does **not** expose a transcription model download/management UI today, so
there is no transcription cancel button to add there. This project does not add one.
(If a transcription download is ever surfaced in Settings later, it should reuse the
same cancel + disk-check behavior.)

## 7. Error Handling Summary

- **User cancel (LLM)** → idle/not-downloaded, partial file deleted, no error shown.
- **User cancel (transcription)** → idle/not-downloaded, model dir deleted, no error
  shown.
- **Genuine download failure** (network, HTTP error, size mismatch, out-of-space
  reached mid-download) → existing `.failed(message:)` path with Retry, unchanged.
- **Insufficient disk at click time** → modal with OK; download never starts; no
  failed state recorded.

## 8. Open Questions / To Validate in Implementation

- **Transcription cancel propagation** — the §4.1 spike + hardware test confirm how
  cleanly the SDK download stops and that cleanup leaves no partial files. Outcome
  is documented back into `specs/research/argmax/` if it reveals SDK behavior worth
  recording.
- **Exact transcription size estimate** — confirm the engine's estimated download
  bytes are a good basis for the §5.2 requirement (vs. the prior hardcoded 1.5 GB).
