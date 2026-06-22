---
status: complete
---

# Functional Spec: LLM Features

## 1. Summary & Goals

Add two on-device AI features to Biscotti, both driven by the existing **`LocalLLM` package / `BiscottiLLM.xpc`** service (which this project **does not modify**):

1. **Summarize** — generate editable markdown meeting notes (with an action-items section) from a transcript.
2. **Identify Speakers** — map diarization speakers ("Speaker 0", "Speaker 1", …) to real people, using the transcript and the calendar invitee list.

Plus the supporting surface: an **"AI Enhancements" settings section**, **model download management**, and the **auto-run orchestration** that runs both features right after a transcription completes.

A secondary, explicit goal: establish **clean in-app patterns for LLM features** — a thin, reusable in-process component that owns scenario logic (prompts, message assembly, output parsing, session orchestration) and keeps the XPC service a *general* LLM service with **no app-specific code**.

### Design tenets
- **App logic is in-process.** A new in-process component (working name **`Intelligence`**, finalized in architecture) owns all scenario logic and talks to the LLM only through the `LocalLLM` client (`LLMService.withConnection` → `LLMConnection.generate` / `generateStreaming`). The XPC service stays generic.
- **Prompts are Swift constants** — a typed prompt catalog in the component (system instructions + user-message templates), not bundled resource files.
- **One LLM session for the auto-run.** Speaker-ID and summary run as two `generate` calls inside a single `LLMService.withConnection` closure so the multi-GB model loads once. (No multi-turn/KV reuse is needed or available — each call is independent; the system message differs anyway.)
- **STT and LLM never co-reside in memory.** `TranscriptionService` shuts the STT engine down (`engine.shutdown()`) before its `transcribe()`/`reTranscribe()` returns, so LLM inference only starts after STT memory is freed.

## 2. Out of Scope (v1)

- **No changes to the `LocalLLM` package or `BiscottiLLM.xpc`** (unless an important bug is found).
- **No onboarding flow.** Users discover/enable AI in Settings (including model download). No first-run prompts.
- **No model selection.** Always the `LocalLLM` default model (Gemma 12B QAT — whatever `ModelDownloader.defaultModelURL`/`modelPath` already points at).
- **No "follow-up email" / other P2 LLM features** — only Summarize and Identify Speakers.
- **No custom-vocabulary work** (blocked upstream; unrelated).
- **No cross-file speaker voiceprint matching** (centroid embeddings remain reserved/empty).
- **No staleness banners** for summaries generated from a now-superseded transcript version (we may store the source transcript ID for bookkeeping, but won't surface "outdated" UI in v1).
- **No manual "re-guess speakers" action.** AI speaker identification runs only via the post-transcription auto-run; afterward, speaker names are edited manually via the sheet. (Documented limitation — see §4.6.)

---

## 3. Feature: Summarize

### 3.1 What it produces
A single markdown document containing the meeting summary **and**, appended at the end, a markdown **"Action Items"** section. This is one LLM call (system instruction + user message with the transcript → assistant markdown), **not** two calls.

### 3.2 LLM contract (functional)
- **System message:** instruction to act as a meeting-notes writer — produce concise markdown notes, then an "## Action Items" section as a checklist; output markdown only.
- **User message:** the meeting transcript, rendered turn-by-turn with **speaker names already resolved** when available (see auto-run order, §5) — otherwise "Speaker 0/1/…".
- **Assistant output:** markdown notes; stored verbatim as the summary.
- **Generation:** streamed (token events) so the Summary tab fills in live.

### 3.3 Storage
On the **`Meeting`** model (like `notes`):
- `summary: String = ""` — markdown source.
- `editedSummary: Bool = false` — set `true` once a human edits the summary (mirrors the existing `editedTitle` pattern). Governs whether auto-run / regenerate may overwrite it.

The summary lives on the meeting and **survives re-transcription** unless regenerated.

### 3.4 Summary tab (meeting detail)
- A new **"Summary" tab, inserted as the FIRST tab** (before Transcript and Notes), via a new first case in `MeetingDetailViewModel.Tab`.
- **Has content:** the summary renders/edits as markdown using the existing `MarkdownEditor` (the same component the Notes tab uses), `isEditable: true`, with a distinct `documentId` (`"<meetingID>-summary"`). Edits autosave with the same debounce-then-flush pattern as notes; the **first user edit flips `editedSummary` to true**.
- **Generating:** while a summary is being produced, the tab **streams** the markdown in as it generates (read-only during the stream), with a subtle "Generating summary…" affordance.
- **Empty state (context-aware):**
  - **Model available, no summary yet:** show a **"Generate Summary"** button (generates from the currently displayed transcript version — see §3.5).
  - **Feature off or no model:** show a short hint pointing to Settings (e.g. "Turn on AI summaries in Settings" / "Download the AI model in Settings"), no Generate button.
  - **No transcript yet:** show nothing actionable (a summary needs a transcript); fall back to the meeting's processing/empty state.

### 3.5 Generating / Regenerating
- **"Generate Summary"** (empty-state button) and **"Regenerate Summary"** ("…" overflow menu) both generate from the **currently selected transcript version** (`activeVersionID` in the detail view — the version shown in the version picker), streaming into the Summary tab.
- **Confirmation:**
  - If the existing summary is **empty or auto-generated** (`editedSummary == false`): regenerate **without confirmation**.
  - If the user **has edited** the summary (`editedSummary == true`): show a **warning/confirmation** ("Replace your edited summary?") before overwriting.
- After a successful (re)generation, the summary is stored with **`editedSummary = false`** (it is AI content again).
- The "Regenerate Summary" menu item is shown whenever a transcript exists and a model is available; it is **disabled while any AI run is in progress** for that meeting.

### 3.6 Errors
- Generation failure (model load, inference, XPC interruption) surfaces a **quiet, inline, dismissible error** in the Summary tab with a **Retry** action. Non-blocking; the rest of the detail view is unaffected.

---

## 4. Feature: Identify Speakers

### 4.1 What it does
Maps each diarization speaker ID (0, 1, 2, …) for a given transcript to a **person** (name, optionally email). Names then replace "Speaker N" everywhere that transcript is displayed. Works two ways:
- **Automatically** via the LLM (post-transcription auto-run), and
- **Manually** via an editing sheet (works even with **no model** — pure manual assignment).

### 4.2 LLM contract (functional)
- **System message:** instruction to infer speaker identities from the transcript and a provided invitee list — e.g. "Hey Daniel, what do you think?" implies the *next* speaker is likely Daniel. Prefer matching to a provided invitee (so we capture their email); otherwise propose a plain name from transcript evidence; leave a speaker unmapped if there's no good evidence.
- **User message:**
  - The **invitee list** when available — each invitee as full name + email (from `calendarContext`), presented as a numbered/labeled list — **or** an explicit statement that no invitee list is available.
  - Always the **meeting transcript** (turn-by-turn with "Speaker N" labels and utterance text).
- **Assistant output:** a **simple line format** (chosen over JSON — far more robust for a local 12B model, and degrades line-by-line). One line per identified speaker:
  ```
  0 | Daniel Lee | daniel@acme.com
  1 | Priya |
  ```
  - Format: `<speakerIndex> | <name> | <email-or-blank>`. Email blank when not confidently tied to an invitee. Omit (or skip) a line for an unidentified speaker. Exact delimiter/edge rules finalized in architecture.
- **Parsing is defensive and line-oriented:** parse each well-formed line independently (tolerating code fences / surrounding prose / blank email); malformed lines are skipped, not fatal. A speaker with no valid line stays "Speaker N". A completely unparseable response simply yields **no mapping** rather than erroring the run.

### 4.3 Resolution to Person
For each mapped speaker, the component resolves a **`Person`** via `findOrCreatePerson(name:email:)`:
- With an email → dedup/link by email (links to the existing invitee/person).
- Name only → dedup by exact name or create a name-only person.

The resulting **speaker ID → `Person.id`** mapping is stored on the transcript (§4.4). Using real `Person` records means a person is **linked across transcripts/meetings** (identity accumulates), per the project's intent.

### 4.4 Storage
On the **`TranscriptRecord`** model (per-transcript, because it changes when re-transcribed):
- A JSON-backed `[Int: UUID]` map of **diarization speaker ID → `Person.id`** (following the existing `vocabularyUsed` `@Transient`/`Data` pattern; working name `speakerAssignments`).
- An empty map means "no assignments" (all show "Speaker N").
- Re-transcription creates a **new** `TranscriptRecord` with an **empty** map — the LLM job or manual mapping must be redone (auto-run will redo it).

To render names, the read model must expose the **numeric speaker ID per segment**: add `speakerID: Int?` to the `SegmentData` DTO (currently only `speakerLabel` is exposed). The meeting-detail read model also needs the transcript's speaker→person map (resolved to names) available to the view.

### 4.5 Display: replacing "Speaker N"
- In the transcript rendering (`TranscriptContent.attributedString()` / `SelectableTranscriptView`), a speaker's label is replaced with the assigned **person's name** when a mapping exists for that segment's `speakerID`; unmapped speakers keep "Speaker N". The stable per-speaker color is keyed off the speaker **ID** (not the display string) so color stays consistent whether or not a name is assigned.
- The stored `TranscriptSegmentRecord.speakerLabel` ("Speaker 0") is **not** mutated; replacement is display-layer (driven by the speaker→person map), so "Copy transcript" and re-runs behave predictably and re-transcription resets cleanly.
- **During the auto-run, labels remain "Speaker 0/1/…"** (so speakers are still distinguishable); they switch to names only once identification completes and the detail view reloads.

### 4.6 Editing sheet (manual mapping)
- Each speaker label in the transcript is **clickable**; clicking opens a **sheet** for that transcript's speaker→person mapping. (Implementation: a `SpeakerLink` URL scheme on the speaker spans handled by the transcript view's `openURL`, mirroring the existing `SeekLink` timestamp pattern.)
- The sheet lists every diarization speaker (Speaker 0…N) for the displayed transcript with its current assignment, each editable via:
  - A **dropdown** to pick from existing people — **meeting invitees first** (`calendarContext.attendees` + organizer), then **all known people** (new `DataStore` read method returning `[PersonData]`).
  - **"Add person…"** free-text to type a new name (creates a **name-only** `Person`).
  - **"Unassigned"** to clear back to "Speaker N".
- The sheet is fully functional with **no model present** — manual speaker naming is independent of AI.
- Saving updates the transcript's speaker→person map and refreshes the transcript display.

### 4.7 Errors
- Auto-run speaker-ID failure (inference/parse) is **silent** beyond the shared subtle "processing/failed" status: labels simply stay "Speaker N". No blocking error. The user can still assign manually.

---

## 5. Auto-Run Orchestration (post-transcription)

### 5.1 Trigger
Runs **once after a transcription completes** — for both the initial recording (`AppCore.stopRecording` → after the existing `await transcription.transcribe(...)`) and a manual **Re-transcribe** (`MeetingDetailViewModel.reTranscribe` → after its `await`). Because `transcribe()`/`reTranscribe()` return only after the transcript is persisted and the STT engine is shut down, this is a reliable, memory-safe hook (no new callback plumbing; we extend the existing awaited Task).

### 5.2 What runs (gated by settings + model presence)
Preconditions: a **model is downloaded** and a transcript was produced. Then, within **one `LLMService.withConnection` session**:
1. **If "Guess Speaker Names" is on:** run **speaker-ID first**, resolve people, persist the speaker→person map to the new transcript.
2. **If "Summarize Transcripts" is on:** run **summary second**, building the user message with the **resolved speaker names from step 1** (better names → better summary). Stream/persist to the meeting.

Order is always speaker-ID → summary. If only one toggle is on, only that step runs (still inside one connection). If neither is on, or no model, the auto-run is skipped entirely.

### 5.3 Edited-content guard
- **Summary:** auto-run **skips** summarization if the meeting's summary is **human-edited** (`editedSummary == true`) — it won't silently overwrite the user's work. (A fresh meeting has `editedSummary == false`, so first-time auto-summary always runs.)
- **Speaker map:** re-transcription yields a fresh transcript with an empty map, so auto speaker-ID always (re)runs for the new transcript; there is nothing to clobber.

### 5.4 Status visibility
- A **subtle, non-modal "processing" indicator** shows while the auto-run is in progress (location finalized in UI design — e.g. in the Summary tab header and/or the meeting row), so the user knows AI work is happening.
- **Speaker labels stay "Speaker 0/1/…"** during the run (no per-label spinner); names appear when identification completes.
- The **summary streams** into the Summary tab as it generates (this is the summary's own progress signal).
- Failures degrade quietly (see §3.6 / §4.7); the indicator clears.

### 5.5 Concurrency
- The `LocalLLM` connection serializes requests; the component runs **one AI session per meeting at a time**. Manual **Generate/Regenerate Summary** is **disabled while an auto-run (or another AI run) is in progress** for that meeting. Transcription remains single-in-flight (existing guard); the auto-run starts only after transcription is fully done.

---

## 6. Settings: "AI Enhancements"

A new section in the existing in-window Settings screen (`SettingsView`, a grouped `Form`), persisted via the SwiftData `AppSettings` model (same pattern as every other setting — optimistic local update + `DataStore.updateSettings`, revert on failure).

### 6.1 Section
- **Header:** "AI Enhancements" with subtitle **"AI runs locally on your Mac."**
- **Toggle 1 — "Summarize Transcripts"**, subtitle "Automatically generate a summary of your meetings." Backed by `AppSettings.summarizeTranscripts` (**default `true`**).
- **Toggle 2 — "Guess Speaker Names"**, subtitle "Use information from the transcript to assign speaker names." Backed by `AppSettings.guessSpeakerNames` (**default `true`**).

### 6.2 No-model state
When **no model is downloaded**:
- Both toggles are **disabled and shown as off** (regardless of stored value).
- A row at the bottom: **"Download Local Language AI Model?"** with a **Download** button and **download status** (idle → progress % / bytes → done / failed-with-retry). A size hint is acceptable (the model is several GB).
- When the download **completes**, the toggles become **enabled** and reflect their stored values (defaults `true`), and the download row disappears (replaced by a subtle "Model installed" state, or simply removed).
- A failed download shows an error with **Retry**.

### 6.3 Model presence is global
Model presence (`ModelDownloader.fileExistsAndNonEmpty(at: modelPath)`) gates: the Settings toggle enablement/download row, the Summary tab's Generate affordance vs. Settings hint, and whether the auto-run executes.

---

## 7. Model Management

- **Default model only**, located at `LocalLLMPaths.defaultModelCacheDir` / `ModelDownloader.defaultModelURL` (already used by the ManualTestApp tab).
- **Presence check:** `ModelDownloader.fileExistsAndNonEmpty(at:)`.
- **Download:** `ModelDownloader.download(from:progress:)` (plain URLSession download — **no XPC**; XPC is only for inference). Progress is surfaced to Settings via an observable download state owned by the in-process component (idle / downloading(bytes,total) / completed / failed).
- **Failures:** network/disk errors show an inline error + Retry in Settings. No resume (the downloader restarts a partial download); that's acceptable.
- **No delete-model UI** in v1 (out of scope; can be added later).

---

## 8. Data Model Changes (summary)

All additive, default-valued fields → **SwiftData lightweight/auto migration** (the store currently has only `DataStoreSchemaV1`; additive defaulted properties need no new schema version or migration stage, per the existing model conventions). If review prefers an explicit `V2`, that's a small addition.

- **`Meeting`**: `summary: String = ""`, `editedSummary: Bool = false`.
- **`TranscriptRecord`**: JSON-backed `[Int: UUID]` speaker→person map (`speakerAssignments`, via `Data` + `@Transient`, mirroring `vocabularyUsed`).
- **`AppSettings`**: `summarizeTranscripts: Bool = true`, `guessSpeakerNames: Bool = true` (+ mirrored in `AppSettingsData`).
- **Read models / DTOs**:
  - `SegmentData`: add `speakerID: Int?`.
  - `MeetingDetailData`: carry `summary`, `editedSummary`, and the resolved speaker→name map (or enough to resolve names for the displayed transcript).
- **`DataStore` methods** (new): set summary (with `editedSummary` control) ; set transcript speaker assignments; `allPersonData() -> [PersonData]` for autocomplete. (Existing `findOrCreatePerson`, `setNotes`, `updateSettings`, `setTitle`/`editedTitle` patterns are the templates.)

---

## 9. Prompt Storage Pattern

Prompts are **Swift constants** organized in a typed catalog inside the in-process component (e.g. an enum/namespace with the summary system prompt, speaker-ID system prompt, and user-message builders). Transcript/invitee data is injected via builder functions (optionally using the `LocalLLM` package's `{{transcript}}` substitution helper). This keeps prompts versioned with the code and reviewable, while remaining app-side (the XPC service stays generic). The catalog is the reusable "pattern" other future LLM features follow.

---

## 10. Cross-Cutting: Errors, Performance, Constraints

- **Apple Silicon, macOS 15+**, on-device only; generation can take many seconds — hence streaming + subtle status.
- **Long transcripts:** the engine's context window (~32k tokens) is mostly available for the transcript (system prompts are small). Extremely long meetings (roughly **~3 hours of audio**) can overflow and **fail** — this is acceptable for v1; it surfaces as the quiet inline summary error (and a silent no-op for speaker-ID). No truncation/middle-out trimming in v1.
- **Memory:** never run STT and LLM engines simultaneously (guaranteed by `engine.shutdown()` before auto-run). One LLM connection at a time; closed promptly after each run so the XPC host can reclaim memory (`_exit(0)` on last-connection).
- **Cancellation:** if a meeting/detail view goes away or the app quits mid-run, the in-flight LLM task is cancelled and the connection closed (no partial summary persisted unless a generation completed).
- **Privacy:** all inference and the transcript/invitee data stay on-device; nothing leaves the machine.
- **Failures are non-blocking and quiet** — AI is an enhancement, never a gate on viewing a meeting/transcript.

---

## 11. Screens / Navigation (functional; details in UI design)

- **Meeting detail → Summary tab** (new first tab): view/edit markdown summary; empty-state Generate; streaming generation; inline error+retry.
- **Meeting detail → "…" menu**: new **Regenerate Summary** item (with edited-summary confirmation).
- **Meeting detail → transcript**: speaker labels show names when assigned; clicking a speaker opens the **Speaker mapping sheet**.
- **Speaker mapping sheet** (new): per-speaker assignment via dropdown (invitees → all people) + add-by-name + unassign; works without a model.
- **Settings → AI Enhancements** (new section): two toggles + conditional model-download row with progress.
- **Subtle auto-run status** indicator (location TBD in UI design).

---

## 12. Decisions Taken (for review)

These were decided with defaults rather than asked — flag any you want changed:

1. **Summary stored on `Meeting`** (per overview), survives re-transcribe; **`editedSummary`** mirrors `editedTitle`.
2. **Speaker map stored on `TranscriptRecord`** as speaker-ID→`Person.id`; resets on re-transcribe.
3. **Speaker-name replacement is display-layer** (stored `speakerLabel` not mutated).
4. **Manual people are name-only** (no email entry in the sheet); emails come only from invitees.
5. **"Unassigned"** option included to clear a speaker.
6. **Auto-run also fires after manual Re-transcribe** (subject to the edited-summary guard).
7. **No manual "re-guess speakers" action** and **no AI speaker-ID for pre-existing/old transcripts** unless re-transcribed — manual sheet covers those. (Limitation.)
8. **Manual "Generate/Regenerate Summary" does summary only** (not speaker-ID).
9. **Additive schema** (no explicit `V2`) unless review prefers otherwise.
10. **No model-delete UI**, **no staleness banner**, **no download resume** in v1.

---

## 13. Polish Revisions (Round 2)

After Phases 1–6 shipped and the UI was reviewed on-screen, the following behavioral refinements were added. They **supersede** the noted earlier sections; everything else stands. Implemented in Phases 7–11 (see `implementation_plan.md`).

### 13.1 Shared processing-pipeline status (supersedes §5.4 and the §11 "subtle auto-run status" pill)
**Problem:** right after a recording, the Summary tab showed the muted "No transcript available." placeholder while transcription was actually still running — misleading, because work *is* happening (transcription → speaker-ID → summary), the summary is just waiting on its dependencies.

- A **shared pipeline status control** renders in the **Summary tab's main content area** while the meeting is processing, showing the ordered stages:
  **`Transcribing` → `Inferring participant names` → `Summarizing`.** Each stage shows **done / active / pending**, and the summary stage is presented as **dependent on the first two** (it stays pending until they complete).
- The control composes **two independent status sources**: `TranscriptionService.jobs[id]` (`.downloadingModel`/`.transcribing`) and `Intelligence.jobs[id]` (`.identifyingSpeakers`/`.summarizing`). A new VM-level computed pipeline model merges them into the ordered stage list.
- **Stage gating ("inlined dependencies"):** only stages that will actually run are shown. "Inferring participant names" appears only when *Guess Speaker Names* is on **and** a model is present; "Summarizing" only when *Summarize Transcripts* is on, a model is present, and the summary isn't human-edited. With no model (or both toggles off) only **Transcribing** shows; when it finishes the tab moves to its normal empty/Generate/content state.
- This control **replaces** the "No transcript available." placeholder on the Summary tab whenever the pipeline is active (the Transcript/Notes tabs keep their existing processing UI).
- The **tab-bar trailing "Summarizing/Identifying speakers…" pill is removed** (§5.4 / UI §5 superseded).
- **Auto-jump:** when the auto-run pipeline becomes active for the open meeting, the detail view **switches to the Summary tab once** (if not already there) so the status — and then the streaming summary — are visible. It does not fight subsequent manual tab changes. (Manual Generate/Regenerate already jumps.)
- **Re-transcribe conformance:** the manual **Re-transcribe** path now calls `runAutoEnhancements` after re-transcription (closing a gap where it previously did not), so the pipeline status and AI re-run cover re-transcription as §5.1 / Decision #6 always intended.

### 13.2 Summary completion: no flash, preserve scroll (refines §3.4(b))
When a streamed summary finishes, the displayed content must **not** flash through an empty/Generate state, and the **scroll position must be preserved**:
- The final markdown populates the editable view **atomically** with the streaming state clearing — there is no frame where `streamingSummary` is `nil` while the persisted `summaryText` is still stale/empty.
- Streaming and final summary render through **one editor instance** (single `documentId`, `isEditable` flipped from `false`→`true`) rather than swapping a `-summary-streaming` editor for a `-summary` editor, so the editor is not recreated and the user's scroll offset is retained. Scrolling already worked *during* streaming; this extends that smoothness across the final token.

### 13.3 Settings layout (supersedes UI §4 footer placement and the §6.1 / §11 section order)
- The **"AI runs locally on your Mac."** caption moves from the Section *footer* to **muted/secondary text trailing the section header** ("AI Enhancements" title · spacer · grey caption), per review.
- **Section order:** Permissions returns to **2nd position, immediately after General**: **General → Permissions → AI Enhancements → Notifications → Calendars** (Debug last in debug builds).

### 13.4 Speaker-assignment provenance — never overwrite a manual assignment (supersedes §4.4 / §8 data shape)
A human's manual speaker→person assignment must **never** be replaced by a later LLM auto-run.
- The per-transcript speaker map gains **per-entry provenance**: each assignment carries a **`userSet: Bool`** flag (stored value becomes `{ personID, userSet }` instead of a bare `UUID`; JSON-backed, with **lenient decode** of the prior `[Int: UUID]` shape → treated as empty/not-user-set, since the feature has no shipped data).
- **Manual** assignment (sheet dropdown pick, Add person…, and re-assign) sets **`userSet = true`**. (Unassign clears the entry.)
- The **LLM auto-run** (`SpeakerIdentifier` → bulk persist) **merges** rather than full-replaces: it **skips any speaker whose current assignment is `userSet = true`**, writing only AI-derived entries for speakers the user hasn't set. AI entries are `userSet = false`.
- Re-transcription still yields a fresh transcript with an empty map (nothing to preserve); the guard matters for re-runs against a transcript a user already touched.

### 13.5 Shared color for merged speakers (supersedes §4.5 / UI §3.1 "color keyed on speaker ID")
Diarization sometimes splits one real person across multiple speaker IDs. When a user maps several speaker IDs to the **same person**, those labels should read as one person — **same name *and* same color**.
- Transcript speaker color is keyed on the **assigned `Person.id`** when a speaker is assigned (so all speaker IDs mapped to one person share that person's color), and falls back to the existing **speaker-ID** key only for unassigned speakers.
- The same rule applies to the **Speaker mapping sheet** row color dots, for consistency.
- Requires plumbing a per-speaker `Person.id` (or precomputed color key) from the resolved read model (`TranscriptData.speakerAssignments: [Int: PersonData]`) to `TranscriptContent`, and including it in the transcript render cache key.
