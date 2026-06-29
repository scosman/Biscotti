---
status: complete
---

# UI Design: Model Download UX

The changes are additive edits to existing components — no new screens. Two new UI
elements: a **Cancel** control in each downloading row, and a **disk-warning alert**.
Everything follows macOS HIG and the existing DesignSystem `Tokens` vocabulary.

## 1. Cancel control

### 1.1 Affordance

- A small **"Cancel"** text button, `.buttonStyle(.bordered)`, `.controlSize(.small)`
  — the same vocabulary the rows already use for Download / Retry / Delete / Choose
  Model.
- **Placement: directly *below* the progress** (bar+`%` or spinner+status), not in
  the trailing action slot. The progress indicator keeps its full width and the
  Cancel button sits beneath it, left-aligned with the progress. This reads cleanly
  and avoids cramping a button against a progress bar in the narrow trailing slot.
- Rationale: text keeps the all-text button vocabulary (an `xmark.circle.fill` icon
  — the App Store/Safari idiom — was considered but would mix a second button style
  into otherwise all-text rows); placing it under the progress is the cleaner layout.
- No confirmation dialog on cancel (functional spec §3.1).

### 1.2 Placement per surface

| Surface / component | Today in `.downloading` | After |
|---|---|---|
| Settings — `ManageModelsSheet` › `ModelRowView` | progress in left column, `EmptyView()` trailing | **"Cancel"** below the progress (left column); trailing slot stays empty |
| Onboarding — `ModelCard` › `DownloadControl`, language row (determinate) | progress bar + `NN%` | **"Cancel"** below the bar + `NN%` |
| Onboarding — `ModelCard` › `DownloadControl`, transcription row (indeterminate) | spinner + status text | **"Cancel"** below the spinner + status text |

- In every case Cancel sits **beneath** the progress indicator, left-aligned with
  it. Progress presentation is otherwise unchanged.

## 2. Disk-warning alert

A standard macOS alert (`.alert`), shown when the click-time disk check fails
(functional spec §5.1). One **OK** button; dismiss-only.

- **Title:** `Not Enough Disk Space`
- **Message:**
  `“{ModelName}” needs about {required} of free space to download, but only {available} is free. Free up some space and try again.`
  - `{required}` = model download size + 2 GB, formatted as `~N GB` / `~N.N GB`
    (reuse the existing `formatBytes` helper).
  - `{available}` = current free space, same formatting.
  - Stating the buffered `{required}` (not the raw model size) is intentional so the
    number the user must clear to actually matches what unblocks the download.
- **Button:** `OK` (default / `.cancel` role) — closes the alert, starts nothing.
- No secondary button, no "Re-check", no "Download anyway" (functional spec §5.1).
- **Ownership:** each surface presents its own alert bound to a small optional state
  value (model name + required + available) set by the tapped Download action and
  cleared on dismiss. Settings presents over `ManageModelsSheet`; Onboarding
  presents over the model-download step.

## 3. Row state transitions (per model row)

State the user sees, and the controls in each:

| State | Content | Action control |
|---|---|---|
| Idle (not downloaded, runnable) | description + `~N GB` size caption | **Download** (trailing) |
| Downloading | progress (determinate bar+`%` for LLM, spinner+status for transcription) | **Cancel** below progress ← new |
| Downloaded + selected | description | "Default" indicator (+ Delete) |
| Downloaded + not selected | description | Choose Model (+ Delete) |
| Failed | "Download failed: …" | **Retry** (trailing) |
| Cannot run (RAM) | description + warning chip, row greyed | — (disabled, unchanged) |

Transitions touched by this project:

- **Download tap → disk check fails** → no state change; **alert shown**; row stays
  Idle.
- **Download tap → disk check passes** → Idle → Downloading.
- **Cancel tap (LLM)** → Downloading → Idle (partial file deleted; *not* Failed).
- **Cancel tap (transcription)** → Downloading → Idle (model dir deleted; *not*
  Failed).

The **insufficient-disk inline state/chip is removed** for the disk dimension
(functional spec §5.3): there is no longer a persistent "insufficient disk" row
appearance — that verdict is delivered only via the alert on tap. The RAM
`cannotRun` chip/greying remains.

## 4. Onboarding footer interaction

Unchanged logic, but note the recompute: the footer shows **Continue** once both
models are "started" (ready or downloading) and **Skip** otherwise (existing
`bothModelsStarted`). Because **Cancel** reverts a download from "started" back to
not-started, cancelling the only in-flight download can flip the footer **Continue →
Skip**, and the "Downloads will continue in the background" caption hides
accordingly. This falls out of the existing derived state once cancel resets the
row; no new footer logic is added.
