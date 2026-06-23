---
status: complete
---

# Functional Spec: Onboarding — Download Models (V2)

A **delta** project. It rewrites the body of the onboarding `.modelDownload` step so the user can
download **both** model classes (transcription + language) from one screen, reusing the existing
download/recommendation/inventory machinery and the existing **Manage Models** sheet. Everything
else in onboarding (window, scaffold, progress header, footer mechanics, other steps) is unchanged.

## 1. Scope

**In scope** — the `.modelDownload` step only:
- Replace the single "Download Now" button (transcription-only) with a **two-row model card**:
  one row for **Transcription & Speaker ID**, one for the **Language Model**.
- Wire the language row to the existing `ModelManager` (recommend / download / track / readiness).
- A **"See all options"** affordance that presents the **existing** Manage Models sheet.
- Footer: show **Skip** until both classes are ready, then **Continue** (extends the existing
  "skip-until-complete" rule from transcription-only to both classes).
- Lead copy + visual structure updates per the design spec (see `ui_design.md`).

**Out of scope** (unchanged):
- The Settings AI Language Model row and the Manage Models sheet's own behavior (beyond making the
  sheet reachable from onboarding).
- The rest of the onboarding flow and the `OnboardingScaffold` / `ProgressHeader` / `BrandFooter`.
- Mid-download cancellation. Skip abandons the step; in-flight downloads continue in the background
  and finish (existing behavior — both subsystems own their own tasks).
- Numeric byte-level progress for the **transcription** download (see Decision D1).
- New product behavior in `ModelManager`, `ModelSuitability`, `ModelPolicy`, the catalog, or the
  transcription pipeline. This project consumes them as-is.

## 2. The two model classes

| Class | Backing | Approx size | Download/state source |
|---|---|---|---|
| **Transcription & Speaker ID** | Whisper V3 Turbo (WhisperKit) | ~1.5 GB | `core.transcription.ensureModelsReady(status:)` + `modelsReady()` |
| **Language Model** | Gemma 4 E2B or 12B (recommended per hardware) | ~3 GB (E2B) / ~7 GB (12B) | `core.modelManager` (`downloadModel`, `downloads`, `recommendedModelID`, `activeModelID`, `isModelAvailable`) |

The two downloads are **independent and concurrent** — they live in different subsystems, so starting
one never blocks the other. (Within the language class, `ModelManager` already enforces one variant
download at a time; that's fine — only one LLM is ever needed.)

## 3. Transcription row

Three states, driven by the existing transcription machinery (no new plumbing):

- **Idle** (not downloaded, enough disk): a **Download** control + size caption "~1.5 GB". Tapping
  calls `startTranscriptionDownload()` → `core.transcription.ensureModelsReady`.
- **Downloading**: an **indeterminate** sage progress bar + the status text the engine emits
  (e.g. "Downloading speech-to-text model"). No %/MB caption — the engine provides only string
  status (Decision **D1**).
- **Ready** (downloaded): the **READY** tag (the existing `GrantedTag`, labeled "READY"). No caption.
- **Blocked — insufficient disk**: Download disabled + an "Insufficient free space on disk" warning,
  when free disk is below the transcription requirement (~1.5 GB; reuse the existing onboarding disk
  check, retargeted to this class).
- **Failed**: status text "Download failed. You can retry or skip." and the Download control returns
  so the user can retry (existing behavior).

Readiness on entry: when the step appears, probe `core.transcription.modelsReady()` so an
already-cached transcription model shows **READY** immediately (e.g. on onboarding replay).

## 4. Language row

State derives entirely from `ModelManager` (no new model state):

- **Target model** (what the easy-path Download pulls and what the row describes) =
  `activeModelID` if a language model is already downloaded/selected, else `recommendedModelID()`.
  `recommendedModelID()` always returns at least E2B, so there is always a valid target.
- **Recommendation line** (idle only): a quiet grey line — `"Recommended · <displayName of
  recommendedModelID()>"` — plus a **"See all options ›"** link that presents the Manage Models
  sheet. No icon/chip (the row's `sparkles` tile already carries the AI cue). Per the design.
- **Idle** (no language model downloaded, none in flight): **Download** control + size caption =
  the target model's `approxDownloadBytes` (e.g. "~3.2 GB"). Tapping calls
  `core.modelManager.downloadModel(id:)` with the target id.
- **Downloading** (any LLM download in flight): a **determinate** sage progress bar + percentage,
  using the in-flight model's `downloads[id] == .downloading(fraction)`. If `fraction` is nil
  (server omitted Content-Length), fall back to an indeterminate bar + "Downloading…".
- **Ready** (`isModelAvailable == true`): the **READY** tag. No caption, no recommendation line.
- **Blocked — insufficient disk** for the target model (`ModelChoice.blockedReason ==
  .insufficientDisk`): Download disabled + "Insufficient free space on disk" warning. (The user can
  still open "See all options" to pick a smaller variant.)
- **Failed** (`downloads[id] == .failed`): error text + Retry, mirroring the sheet's behavior.

Note on low-RAM Macs: 12B is non-runnable and `recommendedModelID()` returns E2B, so the easy-path
Download pulls E2B; the disabled 12B appears only inside the "See all options" sheet. No
onboarding-specific RAM logic — all of it lives in `ModelSuitability`/`ModelManager` already.

## 5. "See all options" — reuse the existing sheet

"See all options" presents the **existing** `ManageModelsSheet` (the same one Settings opens), built
with a `ManageModelsViewModel(core:)`. It already renders both variants, the Recommended badge,
per-variant download/delete/choose, the low-RAM disabling of 12B, and per-variant disk warnings.

Reuse is by **extracting the sheet into a shared `ModelManagementUI` module** that both `SettingsUI`
and `OnboardingUI` depend on (Decision **D3**). The sheet types (`ManageModelsSheet`,
`ManageModelsViewModel`, `ModelRowView`) only depend on `AppCore`/`DesignSystem`/`Intelligence`/
`LocalLLM` — nothing SettingsUI-specific — so the move is a clean, mechanical refactor with no
behavior change. **No fork, no reimplementation.** Downloads or selections made inside the sheet flow
through the shared `ModelManager`, so the language row reflects them automatically on dismiss (it goes
to downloading/ready as appropriate).

## 6. Footer — Skip until both ready, then Continue

- While **either** class is not ready: show only **Skip** ("Skip for now" per design copy; advances
  to `.done`). No top-level primary button — downloads are triggered inside the card rows.
- When **both** are ready (`transcriptionReady && core.modelManager.isModelAvailable`): swap to the
  primary **Continue** button (advances to `.done`).
- Both Skip and Continue advance to `.done`. Skipping leaves models un-downloaded; the app fetches
  them on first use (existing behavior — unchanged). This extends the step's existing
  skip-until-complete rule (`footerButton(for: .modelDownload)`), changing "complete" from
  "transcription downloaded" to "both classes ready".

## 7. Entering the step / state sync

When the `.modelDownload` step is entered (and on replay reset), the view model prepares row state:
- `await core.modelManager.refresh()` so `downloads`/selection reflect on-disk truth (idempotent;
  also runs at app launch).
- `transcriptionReady = await core.transcription.modelsReady()`.
- Recompute the per-row disk checks.

This makes already-downloaded models show **READY** without re-downloading, and surfaces the correct
footer (Continue if both already present).

## 8. Edge cases

- **Already downloaded (one or both):** rows show READY; footer reflects `bothReady` (Continue if both).
- **Insufficient disk:** per-row warning + disabled Download, scoped to that class's size. The other
  class is unaffected (independent checks).
- **Low-RAM Mac:** language easy-path targets E2B; 12B disabled only inside the sheet. No block on the
  language row itself (E2B is always runnable).
- **Download failure:** per-row failed state with Retry; the other row and the footer are unaffected.
- **Concurrent downloads:** both may run at once (different subsystems). Footer stays on Skip until
  both complete.
- **Skip mid-download:** advances to `.done`; in-flight downloads continue and finish in the
  background (no cancellation). On a later visit (or in Settings) they show as ready.
- **Reduced Motion:** honor `accessibilityReduceMotion` — instant state swaps, no springs/pulsing
  (matches the existing onboarding transition handling).
- **Variant changed in sheet then dismissed without downloading:** the row stays idle; the
  recommendation line continues to show `recommendedModelID()` (the easy-path target). Choosing to
  *download* in the sheet moves the row to downloading/ready via the shared `ModelManager`.

## 9. Decisions log (design-spec vs. shipped-code conflicts)

The design spec came from a design agent unaware of the code. Where it conflicted, these are the
resolutions (the human can flip any of them):

- **D1 — Transcription progress is indeterminate (no MB/%).** The design wanted a determinate bar +
  "412 MB / 1.5 GB" for both rows. The transcription engine (`Transcribing` seam) emits only string
  status, not byte counts. Rather than thread byte-level progress through the sensitive Transcription
  package, the **transcription row uses an indeterminate bar + status text**, while the **language row
  shows a real determinate bar + %** (it has byte fractions via `ModelManager`). Honest to each
  subsystem; minimal code. *(Recommended; chosen.)*
- **D2 — Card width 560 (widen the scaffold for this step).** Per the design, the card is **560**.
  The shipped `OnboardingScaffold` caps centered content at `maxWidth: 520`, so the scaffold gains a
  `contentMaxWidth` parameter (default 520) and `OnboardingView` passes **560 for the
  `.modelDownload` step only**. Other steps are unchanged at 520. *(Chosen by human.)*
- **D3 — Reuse the sheet by extracting a shared `ModelManagementUI` module.** "See all options"
  presents the existing `ManageModelsSheet`, moved (with `ManageModelsViewModel` + `ModelRowView` +
  its tests) out of `SettingsUI` into a new shared `ModelManagementUI` module that both `SettingsUI`
  and `OnboardingUI` depend on. Clean DAG (no UI→UI sibling edge); the sheet only ever needed
  `AppCore`/`DesignSystem`/`Intelligence`/`LocalLLM`, so the move is mechanical and behavior-preserving.
  *(Chosen by human — small refactor, good cleanup.)*
- **D4 — "READY" label.** Per the design, the done tag reads **READY** (the transcription step
  previously used "COMPLETE"). Adopted.
- **D5 — Naming.** Code uses the step name `.modelDownload` and the type `OnboardingViewModel`
  (an `@Observable`, not the design's illustrative `OnboardingModel`/`@ObservedObject`). We keep the
  shipped names; the design's code snippets are illustrative only.

## 10. Acceptance criteria

- Title stays "Download Local AI Models"; lead becomes "One-time download. AI runs locally —
  nothing leaves your Mac."
- One card with two rows (transcription, language) divided by an inset hairline, matching the
  Grant-access card chrome, width 560 (scaffold content column widened to 560 for this step only).
- Transcription row: `waveform` tile, Whisper copy, Download + "~1.5 GB" (idle) → indeterminate bar +
  status text → READY.
- Language row: `sparkles` tile, summaries/matching/titles copy, grey "Recommended · <model>" + bold
  grey "See all options ›", Download + size caption (idle) → determinate bar + % → READY.
- No icon next to "Recommended".
- "See all options" opens the existing Manage Models sheet; choices/downloads there reflect back in
  the language row.
- Downloads are independent + concurrent; size caption sits below the Download control.
- Footer shows only Skip until both classes are READY, then Continue. Both advance to `.done`.
- Already-downloaded models show READY on entry (no re-download); footer reflects that.
- Per-row insufficient-disk warning + disabled Download when applicable.
- Reduced Motion: no springs/pulsing; instant swaps.
