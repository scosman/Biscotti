---
status: complete
---

# Functional Spec: Apple Speech Engine

## 1. Goal

Add Apple `SpeechTranscriber` ("Apple Speech") as a second local speech-to-text engine beside Whisper. The user chooses the engine in onboarding and in Settings. Apple Speech is the default on macOS 26+ when it supports the user's language. Whisper stays the only engine on macOS 15.

Why: the validation experiment (`../apple_stt_validation/results/overview.md`) shows Apple is about 5x faster (4.3x measured, with Apple on the slower M2 and Whisper on an M4 Pro) with 3–10x less engine memory, its word timings work with SpeakerKit speaker alignment, and its accuracy is close to Whisper except for technical vocabulary. Whisper stays for users who need jargon accuracy, custom vocabulary, or a language Apple does not support.

**Precedence:** `project_overview.md` and the user's decisions recorded here win over `design_handoff/README.md`. The HTML visuals in `design_handoff/` are reviewed. Where a value already exists in code (spacing, fonts, component metrics), code wins over the mock. Behavior follows the LLM model sheet ("AI Language Model") unless this spec says otherwise; every divergence is listed in §11.

## 2. Terms

| Term | Meaning |
|---|---|
| **Engine** | `apple` (Apple Speech, `SpeechTranscriber`) or `whisper` (WhisperKit, Whisper V3 Turbo). |
| **Speaker ID** | SpeakerKit diarization models. Required by both engines. Separate download (~11 MB). |
| **Apple available** | macOS 26 or later **and** `SpeechTranscriber.isAvailable`. |
| **Apple locale** | The one locale Apple Speech transcribes, e.g. `en_US`. A user setting. |
| **Apple ready** | Apple available **and** the assets for the Apple locale are installed (system `AssetInventory`). |
| **Whisper ready** | The Whisper model is on disk (today's presence check). |
| **Selection** | The engine the user chose, persisted. Empty = no explicit choice. |
| **Recommended** | Policy in §4.2. |
| **Target engine** | Selection if set, else Recommended. The engine that transcribes new meetings. |
| **Effective custom vocabulary** | The user's custom-vocabulary "on" preference **and** target engine = Whisper. |

## 3. Scope

### In scope
1. Apple Speech engine inside the existing `BiscottiTranscriber.xpc` sub-process (still one temporary sub-process per job, as today).
2. Engine + locale passed per job across the transcription API, with minimal API change (§9).
3. Speaker attribution, speaker embeddings/voiceprints, sanitizing and storage work the same for both engines.
4. Speaker ID downloads separately from Whisper.
5. Settings: new "Speech to Text Model" row in AI Enhancements, and the new **Speech to Text Model sheet** (shared by onboarding and Settings).
6. Onboarding "Download Local AI Models" step: 3 rows (Transcription, Speaker ID, Language Model).
7. Apple locale setting with a runtime list of supported locales.
8. Custom vocabulary rules and the two alerts (§7).
9. One-time migration for existing installs (§4.4).
10. Unit tests; manual-test and AI-test additions for the Apple engine (§10).

### Out of scope
- Apple custom vocabulary / contextual strings (unverified with `SpeechTranscriber`).
- Automatic language detection for Apple (the API has none). One locale at a time.
- Changing the Whisper model, Whisper settings, or Whisper vocabulary behavior.
- Re-transcribing old meetings when the engine changes. Changes apply to new transcripts only.
- Live / streaming transcription.
- A Speaker ID management UI in Settings (it downloads in onboarding or on demand at job time, as today).
- Other Apple modules (`DictationTranscriber`, file-input APIs from the 27 SDK).

## 4. Engine Selection

### 4.1 Persistence
- New app setting: **STT engine selection**, stored as a string: `""` (no explicit choice), `"apple"`, or `"whisper"`.
- New app setting: **Apple locale**, stored as a locale identifier. Empty = not chosen yet (resolve per §6.2 each time it is read, and persist it the first time the user changes it or Apple is selected).
- Both live in `AppSettings` (SwiftData, additive fields with defaults; no schema version bump).

### 4.2 Recommendation policy
- **Apple** when Apple is available **and** Apple supports the user's language (some supported locale has the same language as `Locale.current`; see §6.2).
- **Whisper** in all other cases (macOS 15, `SpeechTranscriber` unavailable, unsupported language).
- Recomputed when read; not persisted.

### 4.3 Target engine and changes
- Target = Selection if not empty, else Recommended.
- Selection is written:
  - When the user clicks **Download** on an engine (immediately, before the download finishes — the user's decision is saved as soon as they make it).
  - When the user clicks **Choose Model** on a ready engine.
  - When **Switch to Whisper** is confirmed in the custom vocabulary alert (§7.3).
  - When Whisper is deleted while it is the target (§5.4).
  - When the user clicks **Continue** on the onboarding model step and the saved selection differs from the target (i.e. it is empty): save the target. This locks in the engine the user saw during onboarding, so a later OS update or locale change does not switch it silently.
- Only these actions (and the migration in §4.4) write the selection. Onboarding and Settings share the same selection code. Outside onboarding, a user who never makes a choice follows the recommendation.
- If the selection is `apple` but Apple is no longer available (e.g. impossible downgrade, or `isAvailable` false), the target is Whisper. The stored selection is kept.
- Changing the engine or the Apple locale affects **new** transcripts only. Re-transcribe uses the current target engine and locale.

### 4.4 Migration for existing installs
At launch, if the selection is empty **and** onboarding is complete **and** Whisper is ready, set the selection to `whisper`. This keeps existing users on Whisper (their transcripts do not change without their action). Users who completed onboarding without downloading Whisper get the normal recommendation.

## 5. Downloads and Readiness

### 5.1 Whisper
- Downloads only the Whisper model (Speaker ID is separate).
- Progress: indeterminate (WhisperKit gives no fraction), with today's stage text.
- Size caption: 626 MB.
- Delete: removes the Whisper model folder only. Confirmation: "Delete Whisper?" / "This frees about 626 MB. You can download it again anytime." (LLM pattern).

### 5.2 Apple assets
- "Download" on Apple starts the system asset install for the Apple locale (`AssetInventory` installation request).
- Progress: determinate, using the same progress UI as the LLM sheet ("Downloading… N%", spinner if no fraction).
- No size caption (the system does not expose it); caption "System download".
- No Delete. Apple assets are system-managed.
- If the assets for the Apple locale are not installed (first use, a new locale, or the system evicted them), Apple shows a **Download** button, exactly like any engine that is not downloaded.
- Asset status is re-checked when the sheet opens, when Settings loads, when the onboarding model step appears, and after the locale changes.

### 5.3 Speaker ID
- Downloads only SpeakerKit models (~11 MB). Indeterminate progress.
- Required by both engines.

### 5.4 Delete behavior (mirrors the LLM sheet)
- Delete is shown on a downloaded Whisper even if it is the Default (LLM pattern).
- After Whisper is deleted while it is the target: if Apple is available, the selection becomes `apple`; otherwise the selection stays `whisper` (not ready; Transcription shows Download).
- If custom vocabulary is on and deleting Whisper moves the target to Apple, the delete confirmation adds one sentence: "Custom vocabulary turns off until you switch back to Whisper." (§7.4).

### 5.5 At job time ("same as today")
- The job uses the target engine at job start. It never falls back to the other engine.
- As today, the job downloads what it is missing before it runs: Whisper model and/or Speaker ID for Whisper; Apple locale assets and Speaker ID for Apple. Status messages use today's download-phase gate and copy.
- Download / install failures use today's error mapping and retry flow.

### 5.6 One download at a time
Mirror the LLM sheet: while one engine is downloading, the other engine's Download button is disabled. (A job-time download and a sheet download of the same engine share one in-flight operation; see architecture.)

## 6. Apple Locale

### 6.1 Picker
- Shown inline in the Apple row of the sheet ("1 language" + pop-up menu).
- Options: the runtime list of locales supported by `SpeechTranscriber` (not a fixed list), sorted by display name, each shown as its localized name with region, e.g. "English (United States)", "English (United Kingdom)", "French (Canada)".
- Changing it saves immediately, and updates the Apple row's ready state (assets may need Download).
- Hidden on macOS 15 / when Apple is unavailable (the row shows the trait text "1 language" only).

### 6.2 Default
1. `Locale.current` if supported (`supportedLocale(equivalentTo:)`).
2. Else a supported locale with the same language (prefer the language's primary region, e.g. `fr_FR`).
3. Else `en_US`. (In this case Recommended is Whisper per §4.2.)

### 6.3 Display name
- Summary labels show the **language only**: "Apple Speech ({Language} only)" (e.g. "Apple Speech (English only)"). The region appears only in the picker. Onboarding prepends "Model: " (e.g. "Model: Apple Speech (English only)"); Settings shows the label without the prefix.

## 7. Custom Vocabulary

Custom vocabulary only works with Whisper. The user's stored preference (`customVocabularyEnabled`), word list and "Add Words from Calendar Events" setting are **never changed** by engine switches. While Apple is the target they are inactive; when the target returns to Whisper they apply again.

### 7.1 Transcription
- When the target is Apple, the job sends no vocabulary and records an empty `vocabularyUsed`.
- The "Re-transcribe with keywords from this event?" offer is not shown while the target is Apple (it uses effective custom vocabulary).

### 7.2 Settings toggle display
- The Custom Vocabulary toggle shows **effective custom vocabulary**: it reads **off** while Apple is the target, even if the stored preference is on. Its child rows hide, as for any off state. No badge or caption changes.

### 7.3 Turning the toggle on while Apple is the target
- The toggle does not flip. An alert appears:
  - Title: **"Requires Whisper Transcription"**
  - Message: **"Custom vocabulary only works with the Whisper speech to text model. Switching downloads Whisper (626 MB) and uses it for new transcripts."** When Whisper is already downloaded, drop "downloads Whisper (626 MB) and": "Switching uses Whisper for new transcripts."
  - Buttons: **Cancel** / **Switch to Whisper** (default).
- **Switch to Whisper**: sets selection `whisper`, starts the Whisper download if not ready, and sets the custom vocabulary preference on.

### 7.4 Switching to Apple while custom vocabulary is on
When the effective custom vocabulary is on and the user acts to make Apple the target — **Choose Model** or **Download** on Apple in the sheet — confirm first:
- Title: **"Turn Off Custom Vocabulary?"**
- Message: **"Apple Speech doesn't support custom vocabulary. You need to disable it to switch models."**
- Buttons: **Cancel** / **Turn Off and Switch** (default).
- Confirm → the action proceeds (selection becomes `apple`) and custom vocabulary shows off. The stored preference, word list and calendar setting do not change, so custom vocabulary comes back on if the user switches back to Whisper.
- Delete Whisper that moves the target to Apple: the extra sentence in the delete confirmation (§5.4) replaces this alert.

## 8. UI Surfaces (functional)

Detail in `ui_design.md`.

### 8.1 Speech to Text Model sheet
- Opened from onboarding ("Change…") and Settings ("Manage" / "Download…").
- Two rows: Apple Speech, Whisper. Each shows: Recommended badge (on the recommended engine only), name, selection control (✓ Default if ready + target; Choose Model if ready + not target), 2×2 trait grid, technical line, and the primary action (Download / progress / Delete / none).
- Apple row on macOS 15 or when unavailable: dimmed, no controls, warning chip "Requires macOS 26 or later" + "Learn more…" → alert "Apple Speech requires macOS 26" with **Not Now** / **Software Update…** (opens Software Update settings). When macOS is 26+ but `isAvailable` is false: chip "Not available on this Mac", no Learn more.
- Done closes the sheet.

### 8.2 Settings → AI Enhancements
- New row "Speech to Text Model" between "Summary Prompt" and "AI Language Model".
- Target ready → summary label + **Manage**. Target not ready → **Download…**. Both open the sheet.
- On macOS 15 the sheet still opens (Apple row shown disabled).

### 8.3 Onboarding → Download Local AI Models
- Rows: **Transcription**, **Speaker ID**, **Language Model**.
- Transcription row shows "Model: {summary label}" (e.g. "Model: Apple Speech (English only)" / "Model: Whisper") in `.biscottiMono(11.5)` with a **"Change…"** link (SF 12.5 semibold, `.inkSecondary`, hover/pressed `.ink`). "Change…" opens the STT sheet on every OS (including macOS 15, where the Apple row shows disabled). The line is shown in every state except `.downloading`.
- Language Model row shows "Model: {display name}" (e.g. "Model: Gemma 4 E2B") with a **"Change…"** link opening the Manage Models sheet. If no display name is available, "Change…" still shows but the "Model:" text is omitted. The line is shown in every state except `.downloading`.
- Transcription trailing control: Apple ready → READY + "Built in" (no click); Apple not installed → Download + "System download"; Whisper not ready → Download + "626 MB"; downloading → progress; Whisper ready → READY.
- Speaker ID: Download + "~11 MB" / progress / READY.
- Footer Skip/Continue logic: "all three rows started or ready" (was two).
- Disk check: per row (Whisper and Speaker ID need disk; Apple install is system-managed).

## 9. API Boundary

- `Transcriber`'s public surface changes minimally: the engine and Apple locale are carried by the existing `TranscriptionMethod` extension point plus a locale parameter (exact shape in architecture). Result types (`TranscriptResult` and friends) do not change.
- The XPC request gains the method id and locale. The XPC service stays one temporary process per job.
- Each transcript stores its method id (new Apple id) and its locale in the existing `language` field. The version picker's existing "(methodId)" label shows the new id; no new UI.

## 10. Testing and Validation

- **Spike first (hardware):** confirm `SpeechAnalyzer` + `SpeechTranscriber` + `AssetInventory` run inside `BiscottiTranscriber.xpc` under hardened runtime on macOS 26, with no permission prompt. The user's dev Mac is macOS 15, so this runs on the macOS 26/27 Mac.
- **Unit tests (CI, macOS 15):** selection/recommendation/migration logic, locale default mapping, custom vocabulary rules and alerts (view models), sheet row state, onboarding row state and footer, Settings row, request encoding. Apple framework calls sit behind protocols with fakes.
- **AI tests (`make test-ai`, macOS 26 only, skipped elsewhere):** Apple engine on the existing 3-speaker fixture — non-empty words with timings, speakers assigned.
- **Manual tests:** new `tx_*` steps for the Apple engine (asset install, transcribe a recording, locale change). Mark the Transcription script `not-run` per the staleness rule.

## 11. Divergences from the LLM Sheet (confirmed or to confirm)

| # | LLM sheet | STT sheet | Status |
|---|---|---|---|
| D1 | Download auto-selects only if there is no ready selection | Download always saves the selection immediately | Confirmed by user |
| D2 | If the selection is not downloaded, the first downloaded model is used | The job uses the target and downloads what is missing; no fallback | Confirmed by user ("same as today") |
| D3 | Every model has Delete | Apple has no Delete (system-managed assets) | Required by platform |
| D4 | Size caption from catalog bytes | Apple shows "System download" (no size API) | Required by platform |
| D5 | Determinate progress | Whisper and Speaker ID indeterminate (no fraction from WhisperKit) | Confirmed by user |
| D6 | Width 480 | Width 520 (trait grid) | From design |
