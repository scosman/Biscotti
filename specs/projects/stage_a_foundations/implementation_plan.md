---
status: complete
---

# Implementation Plan: Stage A Foundations

Four stages, one per part, built back-to-back as a single agentic run. Detail for every type/API lives in the four [`components/`](components) docs; this is the sequence and the per-phase "done" check.

**The autonomy rule (see [functional_spec §0](functional_spec.md)).** Every phase **except the very last** must be completable by an agent with no human and no hardware: green on `lint` + `test` (gating) and, where an app/XPC bundle is touched, `build_app` (non-gating) — all via `hooks-mcp`. **All hardware/system/human validation is deferred to the single final phase, "Run the Manual Test App."**

Each phase ends with the standard CR loop + commit (agent commit protocol: `mcp__hooks-mcp__precommit_checks` green, then `git commit --no-verify`). Stages 1–3 are mutually independent; they are ordered risk-first (Transcription → Audio → Data Store). Stage 4 depends on all three.

---

## Stage 1 — Transcription Library  ·  `Packages/Transcription`

→ [`components/transcription.md`](components/transcription.md)

- [x] **Phase 1.1 — Package + pure value/logic core.**
  Create `Packages/Transcription` (`Package.swift` pinning `argmax-oss-swift`, `swift-tools-version: 6.0`); port `ProcessorConfig` (+`ramAware`), `DiarizationStrategy`, `TranscriptResult/Segment/Word`, `VocabularyFormatter`, `TranscriptSanitizer`, `TranscriptionError`, `ModelStatus`.
  **Done when:** `build` + `test` green; `VocabularyFormatterTests`, `SanitizerTests`, `ResultCodableTests`, `ConfigTests` pass.

- [x] **Phase 1.2 — Engine seam + in-process engine + merge + status machine.**
  `TranscriptionEngine` protocol; `InProcessTranscriptionEngine` (refactor of `ArgMaxProcessor` behind the protocol); two-stream merge to mono 16 kHz with label retention; `ModelStatus` transitions; disk-space pre-check.
  **Done when:** `MergeTests`, `StatusMachineTests` pass (stub worker + bundled fixture clip; no live model download).

- [ ] **Phase 1.3 — Client + XPC adapter + error mapping.**
  `Transcriber` actor with `.inProcess` and `.hosted` backends; the `@objc TranscriberServiceProtocol` and the adapter to/from `TranscriptionEngine`; `interruptionHandler` → `workerInterrupted`; `statusStream`.
  **Done when:** `ClientErrorMappingTests` pass (stub connection seam; simulated interruption is retriable). *(The real `.xpc` bundle is built in Stage 4; the hosted path is unit-tested via a seam here.)*

- [ ] **Phase 1.4 — CLI harness (`transcribe-cli`).**
  Argument-parser CLI over the **in-process** engine; JSON `TranscriptResult` → stdout, diagnostics → stderr.
  **Done when:** `CLITests` pass (in-process run over the bundled fixture; nothing non-JSON on stdout).

## Stage 2 — Audio Capture Library  ·  `Packages/AudioCapture`

→ [`components/audio_capture.md`](components/audio_capture.md)

- [ ] **Phase 2.1 — Package + pure logic carry-over.**
  Create `Packages/AudioCapture` (matches BiscottiKit manifest); port `EncoderSettings` (`voiceM4A`), `RMSMonitor`, frame-count + process-parsing helpers, `RecordingFileManager`, `CoreAudioHelpers` (C APIs behind a seam), `CaptureError`.
  **Done when:** `EncoderSettingsTests`, `RMSMonitorTests`, `AudioFrameCountTests`, `AudioProcessTests`, `RecordingFileManagerTests` pass.

- [ ] **Phase 2.2 — Capture engine + route-change + permission inference.**
  `AudioRecorder` actor composing `SystemAudioCapture` (global tap + aggregate device → CAF) and `MicCapture` (AVAudioEngine → CAF); shared start timestamp; CAF→M4A encode on stop (CAF retained on failure); injected route-change rebuild; `probableSystemAudioDenied`; `CaptureState`/`stateStream`.
  **Done when:** `StartAlignmentTests`, `RouteChangeTests` pass (synthetic buffers + injected device-change events; no live audio).

- [ ] **Phase 2.3 — Per-process monitoring.**
  `AudioActivityMonitor` + `ProcessAudioActivity` event stream over `kAudioHardwarePropertyProcessObjectList`.
  **Done when:** `ProcessPropertyListenerTests` pass (synthetic process-list changes).

## Stage 3 — Data Store  ·  `DataStore` module in `BiscottiKit`

→ [`components/data_store.md`](components/data_store.md)

- [ ] **Phase 3.1 — Schema + container + CRUD.**
  Add the `DataStore` target to `BiscottiKit`; `@Model` types (Meeting, TranscriptRecord, AudioFileRef, CalendarSnapshot, AppSettings); `DataStore` actor with `.onDisk`/`.inMemory` storage and CloudKit-off config; `VersionedSchema` + empty `SchemaMigrationPlan`; meeting CRUD + recent/upcoming queries.
  **Done when:** `ContainerTests`, `MeetingCRUDTests` pass against an in-memory container.

- [ ] **Phase 3.2 — Transcripts, audio refs, snapshot, association, search.**
  Versioned transcripts (+ preferred), audio refs + `markAudioPresence`, clearable snapshot, associate/correct, V1 search, the `TranscriptResult`↔`segmentsJSON` bridge.
  **Done when:** `TranscriptVersioningTests`, `AudioRefTests`, `SnapshotTests`, `AssociationTests`, `SearchTests`, `CodableBridgeTests` pass.

## Stage 4 — Manual Test App  ·  `ManualTestApp/` + `ManualTestKit` + `BiscottiTranscriber.xpc`

→ [`components/manual_test_app.md`](components/manual_test_app.md)

- [ ] **Phase 4.1 — `ManualTestKit` (testable harness logic).**
  Add the `ManualTestKit` target to `BiscottiKit`; `TestStep/TestScript/TestStatus/TestResult/CheckOutcome/ResultsStore`; define the two `TestScript`s (Audio Capture, Transcription) as values; the auto-check helpers (file-existence/size, "no segment past duration").
  **Done when:** `ResultsStoreTests`, `ScriptShapeTests`, `CIGateTests`, `CheckOutcomeTests` pass.

- [ ] **Phase 4.2 — App shell (XcodeGen project).**
  Create `ManualTestApp/` (`project.yml`, Info.plist mic+system usage strings, entitlements, non-sandboxed) with a thin SwiftUI `TabView` + generic script-runner view, wiring `ManualTestKit` + `AudioRecorder` + `Transcriber(.inProcess)` for now; results read/written via `ResultsStore`.
  **Done when:** `build_app` (non-gating) builds `ManualTestApp` green; harness logic still `test`-green.

- [ ] **Phase 4.3 — `BiscottiTranscriber.xpc` service + hosted wiring.**
  Create the **shared** glue source in `XPCServices/BiscottiTranscriber/` (`main.swift` entry point, Info.plist, entitlements) linking the `Transcription` package behind `TranscriberServiceProtocol`; declare the `.xpc` target in `ManualTestApp/project.yml` (sources → `../XPCServices/BiscottiTranscriber`); switch the Transcription tab to `Transcriber(.hosted(...))`. *(Project 4's `App/project.yml` later re-declares this same target against these same files — no reimplementation.)*
  **Done when:** `build_app` builds the app **and** the embedded `.xpc` green. *(Real XPC isolation behavior is verified by the human in the final phase.)*

- [ ] **Phase 4.4 — CI gate + CLAUDE.md convention + seed results file.**
  Add `make manual-tests-check` (+ `hooks_mcp` action) and a CI job that fails if any known test id is `not-run`; seed `ManualTestApp/Results/manual_test_results.json` with all steps `not-run`; add the CLAUDE.md staleness rule ("mark a library's manual tests not-run when you touch it").
  **Done when:** `lint`+`test`+`build_app` green; the gate logic is unit-tested and correctly reports the seeded file as **not** all-run. **By design the `manual-tests-check` CI check is RED from here until the final phase** — it is *not* part of the "automated green" bar; it goes green only when the human commits an all-run results file in Phase 4.5.

- [ ] **Phase 4.5 — Run the Manual Test App. ← THE ONLY HUMAN PHASE.**
  A person launches `ManualTestApp` on real Apple-silicon hardware and works through both scripts: real mic + system capture, route-change (AirPods mid-recording), the two permission dialogs, audio quality; real model download/compile, transcription **over the XPC service**, diarized/sanitized output, **worker-crash isolation + retry**, custom-vocab bias. Record pass/fail (+ notes) for every step; commit the updated results file.
  **Done when:** every step is `pass` (or a `fail` is triaged into a follow-up), the results file is committed, and the `manual-tests-check` CI check goes **green**.

---

## Critical path & notes

- **Order:** `1 Transcription → 2 Audio → 3 Data Store → 4 Manual Test App`. Risk-front-loaded (Transcription's XPC/CoreML is the biggest residual unknown, retired by Phase 4.5). 1–3 are independent and could be parallelized; serialized here for one clean run.
- **Green throughout, human once.** Phases 1.1–4.4 are fully autonomous and end green on the automated tiers. Phase 4.5 is the lone human checkpoint; the `manual-tests-check` gate is deliberately red between 4.4 and 4.5.
- **Reuse forward:** the `XPCServices/BiscottiTranscriber/` glue + the Transcription package built in 4.3 are reused verbatim by `App/` in Project 4 (MVP) — `App/project.yml` just re-declares the `.xpc` target against the same shared files. The `Transcriber`, `AudioRecorder`, and `DataStore` APIs are what the MVP's `TranscriptionService`/`Recording` services wrap.
- **Docs to update at the end:** root `CLAUDE.md` (manual-test convention + the new packages), and tick the roadmap (`implementation_plan.md` Projects 1/2/3) as delivered.
</content>
