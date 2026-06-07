---
status: complete
---

# Implementation Plan: Stage A Foundations

Four stages, one per part, built back-to-back as a single agentic run. Detail for every type/API lives in the four [`components/`](components) docs; this is the sequence and the per-phase "done" check.

> **Mid-build correction (recorded).** An audit found the early audio phases (2.1, 2.2) and the first transcription/data designs had drifted from settled research — most importantly the audio container (committed code used **PCM→CAF→M4A**; the validated decision is **ADTS AAC direct**, no CAF). The specs were re-validated against `research/` and re-signed-off, and the data model was reworked (modeled transcript segments, `Person` model, a blended `transcriptionMethodId`, expanded `CalendarSnapshot`). Rather than rewrite history, the committed-but-superseded phases (1.1–1.4, 2.1, 2.2) stay, and dedicated **realign/resolve** phases bring the code to the signed-off specs. See each component doc's "Resolved Research Decisions" / "Code changes vs the committed package" sections.

**The autonomy rule (see [functional_spec §0](functional_spec.md)).** Every phase **except the very last** must be completable by an agent with no human and no hardware: green on `lint` + `test` (gating) and, where an app/XPC bundle is touched, `build_app` (non-gating) — all via `hooks-mcp`. **All hardware/system/human validation is deferred to the single final phase, "Run the Manual Test App."**

Each phase ends with the standard CR loop + commit (agent commit protocol: `mcp__hooks-mcp__precommit_checks` green, then `git commit --no-verify`). Stages 1–3 are mutually independent; Stage 4 depends on all three (at their *realigned* state — 1.5, 2.3, 2.4, 3.x).

---

## Stage 1 — Transcription Library  ·  `Packages/Transcription`

→ [`components/transcription.md`](components/transcription.md)

- [x] **Phase 1.1 — Package + pure value/logic core.** *(committed `2e97564`; partly superseded by 1.5.)*
- [x] **Phase 1.2 — Engine seam + in-process engine + merge + status machine.** *(committed `75099e0`; superseded by 1.5: drops `merged`, `config`.)*
- [x] **Phase 1.3 — Client + XPC adapter + error mapping.** *(committed `7914f09`; superseded by 1.5: drops `config`/`merged`.)*
- [x] **Phase 1.4 — CLI harness (`transcribe-cli`).** *(committed `5fb832e`; superseded by 1.5: drops `--model`/`--merged`.)*

- [x] **Phase 1.5 — Realign Transcription to the signed-off spec.**
  Bring the committed package to the reviewed design (see [`components/transcription.md`](components/transcription.md) → "Code changes vs the committed Phase 1 package"):
  - Replace `TranscriptResult.modelVersion` → **`transcriptionMethodId`**; introduce `TranscriptionMethod` (`.v1` / `.current`).
  - **Remove** the public `ProcessorConfig` + `DiarizationStrategy` input types; fold their settings (model variant, word-timestamps, diarization strategy) into the **internal** method resolver, keeping RAM-aware quantization + sequential-load internal.
  - Drop the `config:` and `mergedPath:`/`merged:` params from `TranscriptionEngine` / `Transcriber` / CLI → `processAudio(mic:system:customVocabulary:)`, `reTranscribe(mic:system:customVocabulary:)` (re-merges from the two sources; **no merged file**). CLI: drop `--model`/`--merged`.
  - Report **real** model-download progress (replace the hardcoded values) and emit `.compiling` / `.loading` separately (SpeakerKit `PyannoteConfig(load:false)` + split download/load).
  **Done when:** `build` + `test` green; tests updated/added — `MethodResolutionTests` (`current.id == "v1"`; RAM logic internal), `ResultCodableTests` (carries `transcriptionMethodId`), `MergeTests`/`ClientErrorMappingTests`/`CLITests` updated for the no-`merged`/no-`config` API.
  > Ground-truth **AI tests** for transcription (real models + a reference clip; tolerance asserts) are **Project 5** in the root roadmap — they need a user-supplied reference audio file, so they're not built autonomously here. This phase only ensures the design supports them (CLI JSON, `Codable` result, in-process engine).

## Stage 2 — Audio Capture Library  ·  `Packages/AudioCapture`

→ [`components/audio_capture.md`](components/audio_capture.md)

- [x] **Phase 2.1 — Package + pure logic carry-over.** *(committed `930c488`; **superseded by 2.3** — `EncoderSettings`/`RecordingFileManager` are CAF/M4A-based, wrong.)*
- [x] **Phase 2.2 — Capture engine + route-change + permission inference.** *(committed `d4c0e81`+`7c3f387`; **superseded by 2.3** — PCM→CAF→M4A, wrong container.)*

- [x] **Phase 2.3 — Resolve 2.1 + 2.2: ADTS AAC rewrite + permission preflight + watchlist.**
  Bring the committed AudioCapture package to the signed-off spec (see [`components/audio_capture.md`](components/audio_capture.md)). Resolves the issues from **both** 2.1 and 2.2 together:
  - **ADTS AAC direct** in both live engines: `kAudioFileCAFType` → `kAudioFileAAC_ADTSType` via `ExtAudioFile`; `EncoderSettings` becomes the ADTS encoder config (`.voice`, `outputASBD()`, `applyBitRate()` with the NULL-`CFArrayRef` ConverterConfig commit; drop `avSettings`/`voiceM4A`).
  - **Delete** `RecordingFileManager.encodeToM4A` and the encode-on-stop step; collapse `CapturePaths` to two `.aac` URLs; `stop()` returns nothing (files final as written); remove `conversionFailed`/`partialEncodeFailed`; add `micPermissionDenied`.
  - Keep route-change **file-preserving** (already correct); add **mic `AVCaptureDevice.authorizationStatus` preflight** (refuse-to-start on denied); add `com.apple.avconferenced` + `com.apple.WebKit.GPU` to the seed watchlist.
  **Done when:** `build` + `test` green; tests reworked — `EncoderSettingsTests` (ADTS/24k/mono/64k + `outputASBD`/`applyBitRate`), `StartAlignmentTests`, `RouteChangeTests` (file-preserving; only initial `start` creates the file), permission-preflight test; CAF/M4A tests removed.

- [x] **Phase 2.4 — Per-process monitoring.**
  `AudioActivityMonitor` (never built) + `AudioProcess` event stream — **push-based** per-process `kAudioProcessPropertyIsRunning` listeners (NOT `IsRunningInput`/`Output`), reconciled against `kAudioHardwarePropertyProcessObjectList` changes.
  **Done when:** `ProcessPropertyListenerTests` pass (synthetic process-list + running-state changes).

## Stage 3 — Data Store  ·  `DataStore` module in `BiscottiKit`

→ [`components/data_store.md`](components/data_store.md)

- [x] **Phase 3.1 — Schema + container + CRUD + people.**
  Add the `DataStore` target to `BiscottiKit`; the `@Model` types per the signed-off schema — `Meeting`, `Person` (many-to-many `participants` + one-to-many `organizer`, SwiftData-native inverses), `TranscriptRecord`, `TranscriptSegmentRecord`, `TranscriptWordRecord`, `AudioFileRef` (mic/system), `CalendarSnapshot` (expanded fields + link keys), `AppSettings`; `DataStore` actor with `.onDisk`/`.inMemory` storage, CloudKit-ready-but-off config; `VersionedSchema` + empty `SchemaMigrationPlan`; meeting CRUD + recent/upcoming; `findOrCreatePerson` / `setParticipants`.
  **Done when:** `ContainerTests`, `MeetingCRUDTests`, `PeopleTests` pass against an in-memory container.

- [x] **Phase 3.2 — Transcripts (modeled segments + input tracking), audio refs, snapshot, association, search.**
  Versioned transcripts mapping `TranscriptResult` → `TranscriptSegmentRecord`/`TranscriptWordRecord` rows (ordered via `index`); record inputs (`transcriptionMethodId`, `vocabularyUsed`, `mappedEventIdentifier`) + `preferredTranscriptIsStale`; audio refs + `markAudioPresence`; clearable snapshot; associate/correct; basic title+participant `search` (transcript-text search deferred to Project 7).
  **Done when:** `TranscriptVersioningTests`, `TranscriptInputTrackingTests`, `SegmentMappingTests`, `AudioRefTests`, `SnapshotTests`, `AssociationTests`, `SearchTests` pass.

## Stage 4 — Manual Test App  ·  `ManualTestApp/` + `ManualTestKit` + `BiscottiTranscriber.xpc`

→ [`components/manual_test_app.md`](components/manual_test_app.md). Depends on the **realigned** libraries (1.5, 2.3, 2.4, 3.x).

- [ ] **Phase 4.1 — `ManualTestKit` (testable harness logic).**
  Add the `ManualTestKit` target to `BiscottiKit`; `TestStep/TestScript/TestStatus/TestResult/CheckOutcome/ResultsStore`; define the two `TestScript`s (Audio Capture, Transcription) as values; auto-check helpers (two `.aac` exist + sane size, "no segment past duration").
  **Done when:** `ResultsStoreTests`, `ScriptShapeTests`, `CIGateTests`, `CheckOutcomeTests` pass.

- [ ] **Phase 4.2 — App shell (XcodeGen project).**
  Create `ManualTestApp/` (`project.yml`, Info.plist mic+system usage strings, entitlements, non-sandboxed) — thin SwiftUI `TabView` + generic script-runner, wiring `ManualTestKit` + `AudioRecorder` + `Transcriber(.inProcess)` (realigned API); results via `ResultsStore`.
  **Done when:** `build_app` (non-gating) builds `ManualTestApp` green; harness logic still `test`-green.

- [ ] **Phase 4.3 — `BiscottiTranscriber.xpc` service + hosted wiring.**
  Create the **shared** glue in `XPCServices/BiscottiTranscriber/` (`main.swift`, Info.plist, entitlements) linking the `Transcription` package behind `TranscriberServiceProtocol`; declare the `.xpc` target in `ManualTestApp/project.yml` (sources → `../XPCServices/BiscottiTranscriber`); switch the Transcription tab to `Transcriber(.hosted(...))`. *(Project 4's `App/project.yml` later re-declares the same target against these same files — no reimplementation.)*
  **Done when:** `build_app` builds the app **and** the embedded `.xpc` green.

- [ ] **Phase 4.4 — CI gate + CLAUDE.md convention + seed results file.**
  Add `make manual-tests-check` (+ `hooks_mcp` action) and a CI job that fails if any known test id is `not-run`; seed `ManualTestApp/Results/manual_test_results.json` all `not-run`; add the CLAUDE.md staleness rule.
  **Done when:** `lint`+`test`+`build_app` green; gate logic unit-tested + correctly reports the seed as not-all-run. **By design `manual-tests-check` is RED from here until 4.5** — not part of the "automated green" bar.

- [ ] **Phase 4.5 — Run the Manual Test App. ← THE ONLY HUMAN PHASE.**
  A person runs `ManualTestApp` on real Apple-silicon hardware: real mic+system capture, the two permission dialogs, route-change (AirPods mid-recording), **crash-safety** (kill mid-record → partial `.aac` still decodes), audio quality; real model download/compile, transcription **over the XPC service**, diarized/sanitized output, **worker-crash isolation + retry**, custom-vocab bias. Record pass/fail (+ notes); commit the results file.
  **Done when:** every step `pass` (or a `fail` triaged to a follow-up), results committed, `manual-tests-check` goes **green**.

---

## Critical path & notes

- **Order:** `1 Transcription (incl. 1.5 realign) → 2 Audio (2.3 resolve + 2.4 monitor) → 3 Data Store → 4 Manual Test App`. 1–3 independent; serialized for one clean run.
- **Green throughout, human once.** Every phase through 4.4 ends green on the automated tiers; Phase 4.5 is the lone human checkpoint (the `manual-tests-check` gate is deliberately red between 4.4 and 4.5).
- **Superseded phases kept, not rewritten.** 1.1–1.4 / 2.1 / 2.2 remain in history; 1.5 and 2.3 carry the code to the signed-off specs. This is the agreed "fix forward" approach.
- **Reuse forward:** the `XPCServices/BiscottiTranscriber/` glue + Transcription package are reused verbatim by `App/` in Project 4 (re-declares the `.xpc` target against the same files). `Transcriber` / `AudioRecorder` / `DataStore` APIs are what the MVP's services wrap.
- **Out to other projects:** ground-truth **AI test set** (transcription) = root-roadmap **Project 5** (needs a user-supplied reference clip); transcript-text **search** design = **Project 7**.
- **Docs to update at the end:** root `CLAUDE.md` (manual-test convention + new packages) and tick the roadmap Projects 1/2/3 as delivered.
</content>
