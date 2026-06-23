---
status: complete
---

# Functional Spec: LLM Model Selection

## 1. Goal & Context

Today Biscotti ships a single hard-coded local LLM — **Gemma 4 12B QAT** — used for all AI
analysis (summary, speaker-name inference, title). The 12B model needs ~8 GB RAM and is slow on
M1/M2 Macs, and won't run at all on low-RAM machines.

This project lets the user **choose between multiple local LLMs**, **smart-suggests** an appropriate
one for their hardware, and **prevents** choosing a model the machine can't run. Two models ship
initially (12B and a smaller E2B), but the design is explicitly built to grow to more.

Both models are Gemma 4, so they share the same chat template / message structure — no changes are
needed below the app layer (`LocalLLM`'s `GemmaChatTemplate`, the XPC service, and
`LLMService.withConnection(model:)` already accept any GGUF path).

## 2. Model Catalog

The system is driven by a **catalog** of model descriptors. Initially two entries; adding a model
later = adding one descriptor (no UI or logic rewrites). Each descriptor carries:

| Field | 12B | E2B |
|---|---|---|
| `id` (stable, persisted) | `gemma-4-12b` | `gemma-4-e2b` |
| Display name | `Gemma 4 12B` | `Gemma 4 E2B` |
| Description (UI copy) | "Intelligent, but slower and larger. Requires 7 GB of disk and uses 8 GB RAM." | "Small and fast, but not as intelligent. Requires 3 GB of disk and uses 4 GB of RAM." |
| Download URL | `https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/gemma-4-12b-it-UD-Q4_K_XL.gguf` (existing) | `https://huggingface.co/unsloth/gemma-4-E2B-it-qat-GGUF/resolve/main/gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf` (new) |
| On-disk filename | `gemma-4-12b-it-UD-Q4_K_XL.gguf` | `gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf` |
| Required disk (download size, free-space gate) | 7 GB | 3 GB |
| Required-to-run RAM floor | 15 GB | none (runs on any supported Mac) |

- The two filenames differ, so both models **coexist on disk** in the existing cache directory
  (`~/Library/Application Support/Biscotti/llms/`). No migration of existing files needed.
- Catalog **display order** is: 12B, then E2B (used for fallback selection tie-breaks and sheet
  row order).
- The "required disk" / "required RAM" numbers in the description copy are the values used by the
  gates below — single source of truth per descriptor.

## 3. Hardware Suitability & Recommendation

Three independent, per-model facts are computed from hardware. **Only physical RAM and free disk
space are read** — there is **no chip-generation or Intel/Apple-Silicon detection** (builds are
Apple-silicon-only, and brand-string chip parsing is fragile and unworthy of the complexity).

### 3.1 Can-run (hard gate)

A model is **runnable** on this Mac iff its RAM floor is met:

- **12B is runnable iff** physical RAM ≥ **15 GB**.
- **E2B is runnable** on any supported Mac.

If a model is **not runnable**, it appears in the Manage sheet **greyed-out and disabled**, with the
warning **"This Mac can't run this model"**. It cannot be downloaded or selected. (This is the
single, confirmed rule that supersedes the looser "don't show on 8 GB" note — an 8 GB Mac is < 15 GB,
so 12B is greyed there.)

### 3.2 Recommendation (soft hint)

Exactly **one** model is marked **"Recommended"** via a badge:

- If RAM ≥ **24 GB** → recommend **12B**.
- Otherwise → recommend **E2B**.

The recommendation never points at a non-runnable model (recommending 12B requires ≥ 24 GB ≥ 15 GB,
so it is always runnable when recommended). E2B is always runnable.

### 3.3 Disk-space gate

A model's **Download** action is disabled when **free disk space < the model's required disk size**,
with the warning **"Insufficient free space on disk"**. (Free space is measured the same way the
rest of the app does — `volumeAvailableCapacityForImportantUsageKey` on the home volume.) Already-
downloaded models are unaffected by this gate.

### 3.4 Hardware detection requirements

The app must detect, at runtime, only:

- **Physical RAM** in bytes (`ProcessInfo.physicalMemory`, already used elsewhere).
- **Free disk space** on the home volume (`volumeAvailableCapacityForImportantUsageKey`, already
  used elsewhere).

No chip-generation, architecture, or Intel detection is performed. These reads are abstracted behind
a protocol so the suitability rules (can-run, recommendation, disk gate) are unit-testable with fake
hardware/disk profiles.

## 4. Selection & Persistence

### 4.1 The setting

A new persisted setting **`selectedModelID: String`** is added to `AppSettings` (default `""`). It
records the user's chosen model by stable `id`.

### 4.2 Active model (what the AI actually uses)

The **active model** — the GGUF loaded for all AI analysis — is resolved as:

1. If `selectedModelID` names a model that is **downloaded** → that model.
2. Else, the **first downloaded model in catalog order** (if any).
3. Else → **none** (no active model; AI features are unavailable).

When step 2 resolves a model because the stored selection was empty or stale, the app
**persists** that id back into `selectedModelID` (so the sheet's "Default" label and the settings
row are stable). This also provides **seamless migration**: existing users who already downloaded
12B have an empty selection, so on first launch the active model resolves to the downloaded 12B and
selection is persisted — behavior is unchanged for them.

### 4.3 When selection changes

- **First successful download while no valid selection exists** (selection empty or names a
  non-downloaded model) → the just-downloaded model becomes selected automatically.
- **"Choose model"** on a downloaded, runnable model → sets `selectedModelID` to it.
- **Deleting the selected model** → selection is recomputed: the first remaining downloaded model
  (catalog order) becomes selected; if none remain, selection is cleared (`""`).

A model can only be selected if it is **downloaded** and **runnable**.

## 5. Settings — "AI Language Model" Row (always visible)

The current behavior — a download row that only appears when no model is on disk — is **replaced**
by a **permanent row** in the existing **AI Enhancements** section:

- **Title:** "AI Language Model"
- **Subtitle:** "The AI model used to summarize meetings"
- **Trailing content, by state:**
  - **Active model exists** → the model's display name in **grey/secondary text** (same visual
    treatment as granted-permission rows, e.g. "Gemma 4 12B") **+ a "Manage" button** that opens the
    Manage Models sheet.
  - **No model downloaded** → a **"Download…" button** that opens the Manage Models sheet.
  - *(Transient, low priority)* While a download is in progress and no model is yet active, the row
    may show "Downloading… N%" alongside the Manage button. Acceptable to show "Download…"/ "Manage"
    only; the sheet is the authoritative place for progress.

The existing **"AI Analysis & Summary" toggle** keeps its current gating: it is **disabled while no
model is available** (no active model). Its label/description are unchanged.

The old inline `modelDownloadRow` (progress/retry shown directly in the AI section) is **removed** —
all downloading now happens inside the Manage Models sheet.

## 6. Manage Models Sheet

A sheet (same presentation pattern as existing Settings sheets) titled e.g. **"AI Language Model"**,
listing every catalog model as a row. Designed to scale to N models.

### 6.1 Row anatomy

Each row shows:

- **Model name** (primary) — with a **"Recommended"** badge on the recommended model.
- **Description** (secondary copy from the catalog).
- **A primary action** depending on download state (Download / Delete / progress).
- **A selection control** depending on selection state (Default label / Choose model).
- **A warning** when the model is blocked (can't-run or insufficient-disk).

### 6.2 Per-row state matrix

For each model, the row renders one coherent state:

| Condition | Row appearance |
|---|---|
| **Not runnable** (12B on RAM < 15 GB) | Greyed-out/disabled; warning **"This Mac can't run this model"**; no Download/Choose actions. |
| **Runnable, not downloaded, insufficient disk** | **Download** button **disabled**; warning **"Insufficient free space on disk"**. |
| **Runnable, not downloaded, enough disk** | **Download** button (enabled). |
| **Downloading** | Progress (determinate `ProgressView` + "Downloading… N%", or indeterminate when no Content-Length). |
| **Download failed** | Error message + **Retry**. |
| **Downloaded, not selected** | **Delete** button **+ "Choose model"** button. |
| **Downloaded, selected** | **Delete** button **+ "Default"** label (grey). |

### 6.3 Actions

- **Download** → starts the download for that model (see §7). Progress shows inline in the row.
- **Delete** → removes that model's GGUF from disk (see §7), then updates selection per §4.3.
- **Choose model** → makes that model the selected/default (§4.3).
- The sheet is dismissable (Done/Close); dismissing **does not** cancel an in-flight download — it
  continues in the background and is reflected when the sheet is reopened.

### 6.4 Concurrency

**Only one download runs at a time.** While any model is downloading, the **Download** action on
other not-downloaded rows is **disabled** (the in-flight row shows progress). Delete/Choose on other
rows remain available. This avoids saturating bandwidth/disk with concurrent multi-GB downloads.

## 7. Download & Delete Behavior

### 7.1 Download

- Reuses the existing downloader (temp-file → atomic move, skip-if-present, Content-Length size
  validation, no resume). The only change is **which URL/filename** is used (per descriptor) instead
  of the single hard-coded default.
- Progress is reported and throttled exactly as today (update on ≥ 1% movement).
- On success: the file lands in the shared cache dir; if no valid selection existed, this model
  becomes selected (§4.3).
- On failure: row shows the error with **Retry**. (Failure leaves no partial file — existing temp-
  cleanup behavior.)
- Errors are surfaced as today (short message from `LocalLLMError`/underlying error).

### 7.2 Delete

- Removes the model's GGUF file (and any stray `.partial`) from the cache directory.
- A lightweight **confirmation** precedes deletion (e.g. "Delete Gemma 4 12B? You can download it
  again anytime."), since it discards a multi-GB download.
- After deletion, selection is recomputed (§4.3). If the deleted model was the active one and no
  other model is downloaded, AI features become unavailable until another model is downloaded (the
  AI toggle disables, the settings row reverts to "Download…").
- Deleting a model that is **mid-analysis** is out of scope to specially handle — analyses run from
  an already-opened session; a new analysis simply uses the new active model (or no-ops if none).

## 8. AI Analysis Integration

- All AI analysis paths (`runAutoEnhancements`, manual `runAnalysis`) must load the **active
  model's** GGUF rather than the hard-coded default. The active model id comes from settings and is
  resolved to a file URL via the catalog at session start.
- The existing guard "no model on disk → no-op" becomes "**no active model → no-op**" (unchanged
  user-visible behavior: AI silently does nothing when nothing is available).
- Switching the selected model takes effect on the **next** analysis run; an in-flight run completes
  with the model it started with.
- No prompt/template changes: both models use the same Gemma 4 chat template, tokens, and the
  existing context-sizing logic.

## 9. Library (`LocalLLM`) API Additions

Per the overview's "might need an API to list downloaded models" — added **in-process** (no XPC):

- A **catalog** of model descriptors (id, display name, download URL, filename, download size).
- A way to resolve a descriptor's **on-disk path** in the shared cache dir, and to check **whether
  each catalog model is downloaded** (the "list downloaded models" capability is: for each catalog
  entry, does its file exist and is non-empty — reusing `fileExistsAndNonEmpty`).
- The downloader already accepts an arbitrary source URL; multi-model support uses per-descriptor
  URL + filename rather than the single `defaultModelURL`/`modelPath`. The existing
  `defaultModelURL` may remain (for the CLI) but the app no longer assumes a single model.
- A **delete** capability for a model file (used by the sheet).

App-level product policy — hardware thresholds, recommendation, disk gate, UI copy — lives in the
app layer (BiscottiKit/SettingsUI), **not** in `LocalLLM`, to keep the library free of product
policy.

## 10. Edge Cases

- **Existing user, 12B already downloaded:** empty selection resolves to downloaded 12B and is
  persisted; nothing visibly changes. The sheet shows 12B as Default + Delete, E2B as Download.
- **Selected model file deleted out-of-band** (user removes it in Finder): on next settings load /
  AI run, active model falls back to another downloaded model or none; selection is re-persisted.
- **Recommended model is 12B** (e.g. 24 GB Mac): no conflict; 12B is both runnable and recommended.
- **Borderline middle band** (e.g. 16 GB Mac): 12B is **runnable** (≥ 15 GB) but **E2B is
  recommended** (fails the ≥ 24 GB rule). Both are selectable; the badge guides without forcing.
- **No internet during download:** download fails with an error + Retry; no partial file remains.
- **Insufficient disk that becomes sufficient** (user frees space) and reopens sheet: the Download
  button re-enables (state is recomputed when the sheet appears / on relevant changes).
- **Both models downloaded, user deletes the non-selected one:** selection unchanged; row flips to
  Download.
- **Future model added to catalog:** appears as a new row automatically; recommendation/gates apply
  via its descriptor; no code changes in the sheet/row.

## 11. Out of Scope

- Download **resume**, checksum/SHA verification, and a general download manager (tracked for
  Project 10 — unchanged by this work).
- **Cancelling** an in-flight download from the UI (the underlying code tolerates cancellation, but
  no Cancel button is added now).
- Arbitrary **user-supplied** model URLs / custom models (catalog is curated).
- Per-model **runtime tuning** (context size, GPU layers) beyond what exists — both Gemma 4 variants
  use current defaults.
- Changing transcription models (this project is the **LLM** model only).

## 12. Constraints & Notes

- **Apple-silicon-only, macOS 15+** (per repo conventions). Builds are not shipped for Intel, so no
  architecture detection is needed — RAM is the only gate.
- **Manual-test staleness:** this project touches `Packages/LocalLLM`. Per the repo rule, the
  `llm_*` manual-test steps must be marked `not-run` so the manual-test gate flags them for a human
  hardware re-run.
- **Manual-test coverage (new):** the ManualTestApp "Local LLM" tab gains **E2B validation** — one
  step to **download** the Gemma 4 E2B model and one step to run the **multi-turn (KV-cache reuse)**
  inference through `BiscottiLLM.xpc` on E2B, plus an observation. This is the single most demanding
  path for a maximum-compatibility check of the new GGUF; the rest of the suite is **not** repeated
  for E2B. The app-level selection UI (settings row + sheet) is validated by running the real app,
  not this harness.
- No new third-party dependencies; hardware detection uses `ProcessInfo.physicalMemory` and
  `volumeAvailableCapacityForImportantUsageKey` from Foundation only.
```
