---
status: complete
---

# Functional Spec: Stage A Foundations

Four parts in one spec, built as a single agentic run:

1. **Transcription Library** (`Packages/Transcription`) — Project 1.
2. **Audio Capture Library** (`Packages/AudioCapture`) — Project 2.
3. **Data Store** (`DataStore` module in `Packages/BiscottiKit`) — Project 3.
4. **Manual Test App** (`ManualTestApp/` Xcode project) — the harness that hosts the real XPC service and validates the hardware/system behavior of parts 1 & 2.

This document specifies **what** each part must do and the contracts between them. Concrete API shapes (types, signatures) live in the four `components/*.md` docs. The static topology (homes, boundaries, dependency edges) is already fixed by the repo [`architecture.md`](../../../architecture.md) and is **not** re-litigated here.

**Grounding:** Parts 1 and 2 productionize `experiments/ArgMaxKit` and `experiments/AudioLab`. The hard technical unknowns are already resolved by the completed `research/` project (see [`research/argmax`](../../../research/argmax/README.md), [`research/audio`](../../../research/audio/README.md), [`research/permissions`](../../../research/permissions/README.md)). **We consume those findings; we do not re-derive them.** For parts 1 & 2 this is primarily a **packaging, testing, and API-design** exercise.

---

## 0. The defining constraint — autonomy until the final phase

The reason these four parts are combined is to run them as **one long autonomous build**. The implementation plan MUST be ordered so:

- **Every phase except the last** is completable by an agent with no human and no hardware: it builds and passes **unit/integration tests** through `hooks-mcp` (`build`, `test`, `lint`, and where an app bundle is involved `build_app`). Tests use stubs/seams and bundled fixtures — never a live mic, live system audio, live CoreML model download, or a real permission prompt.
- **All hardware-, system-, and human-dependent validation is deferred to the single final phase: "run the Manual Test App."** This is the only point a human is required.

Concretely, the following can only be confirmed by the final phase and MUST NOT gate any earlier phase: real two-stream capture quality, route-change survival on real devices, the real permission dialogs, on-device CoreML model download/compile, real XPC crash-isolation under memory pressure, and "is the audio/transcript actually good."

A correct Stage A therefore reaches the last phase **fully green on automated checks**, with a written, interactive manual-test script waiting to be run once by a person.

---

## Part 1 — Transcription Library

### 1.1 Purpose

Turn a recording's audio files into a rich, diarized transcript, fully on-device, in a crash-isolated worker process. Productionizes `experiments/ArgMaxKit` (already an SPM package with `ArgMaxProcessor`, `TranscriptResult`, `VocabularyFormatter`, an error type, and a CLI).

### 1.2 Features & behaviors

- **Diarized transcript from labeled audio files.** Input is a **set of labeled audio file paths** (mic stream + system stream), not a pre-merged blob. The library **owns the merge/mux** to the single mono 16 kHz `[Float]` the SDK consumes (per [research §5](../../../research/argmax/README.md): SDK takes one merged array; no time-aligned multi-stream API). Stream provenance (which file is mic vs. system) is **retained as a labeled input** so a later project can use it for "me" identification — V1 only needs to merge correctly and not lose the labels.
- **STT + diarization pipeline.** WhisperKit (`openai_whisper-large-v3_turbo`, or a quantized variant) + SpeakerKit (Pyannote v4 community-1), merged via `addSpeakerInfo(to:)` with a selectable strategy (`.subsegment` default / `.segment`).
- **Model management.** Download, cache, delete; disk-space pre-check before download; rich status that a UI can drive: `needsDownload`, `downloading(progress)`, `compiling`, `loading`, `ready`, `running`, `error`. Variant selection (full-precision vs. quantized) is caller-configurable with a sensible RAM-aware default.
- **Crash-isolated worker.** An in-process **client** talks to an out-of-process **worker** over `NSXPCConnection`. The worker hosts WhisperKit/SpeakerKit; the app/library client never imports them directly. On worker crash the `interruptionHandler` fires, the next call auto-relaunches the worker (launchd), and the client surfaces a retriable error. **The `.xpc` service bundle itself is glue that lives in a host app** — in Stage A that host is the Manual Test App (decided); the package provides everything except the bundle/Info.plist/entry-point. The library MUST also expose an **in-process fallback path** (background actor) usable when no XPC host is present (e.g. the CLI harness and unit tests), per the research fallback.
- **Memory lifecycle.** Explicit load / unload; sequential STT-then-diarize with unload-between as the memory-safe mode for 8 GB Macs; both-resident allowed on 16 GB+.
- **Custom-vocabulary biasing.** Accept a `[String]` vocabulary; format into a natural-language prompt; tokenize and pass as `promptTokens` (the free-SDK workaround, ~224-token budget). API takes the `[String]` so a future Pro-SDK swap needs no caller change. (`VocabularyFormatter` already exists in the experiment.)
- **Output sanitization (mandatory, from validation).** Before returning a transcript: **drop/clamp segments whose start/end exceed the actual audio duration** (Whisper end-of-audio hallucination — a "Thank you" at 52.5 s on a 25.1 s clip was observed, [gotcha #14](../../../research/argmax/README.md)); treat **segment-level `confidence` as unreliable** (came back `0` in free SDK v1.0.0 — derive any confidence from word-level `probability`, [gotcha #13]); optionally drop very-low-confidence trailing single-word segments.
- **Re-transcribe.** Re-run an existing recording (e.g. after vocab change). The result records the model version used so versions can be compared/stored.
- **CLI harness.** Successor to `argmaxkit-cli`: take audio file path(s) + options, print the rich transcript as JSON to **stdout**, all diagnostics/progress to **stderr** ([gotcha #15]). The CLI exercises the **in-process path** (no XPC host), keeping it runnable under `swift run` / tests.

### 1.3 Contracts

- **In:** ordered, labeled audio file URLs (mic, system); a config (model variant, repo, word-timestamps on/off, diarization strategy); an optional `[String]` custom vocabulary.
- **Out:** a rich `Codable`, `Sendable` transcript value — segments with speaker id/label, start/end, text, word-level timings + probabilities, detected language, speaker count, model version, processing duration. A reserved (empty in v1.0.0) speaker-embeddings field for future cross-file matching ([§6 erratum]).
- **Errors:** a typed error taxonomy covering needs-download, insufficient-disk, download-failed, model-load-failed, worker-unavailable/crashed (retriable), transcription-failed, invalid-input. (`ArgMaxError` exists in the experiment as a starting point.)

### 1.4 Edge cases

- Offline on first run → models can't download → `needsDownload`/download-failed with a clear, retriable error (no silent hang). SpeakerKit's ~33 MB model MAY be bundled; the multi-GB STT model cannot ([gotcha #8]).
- First-load CoreML compile is 15–90 s → surfaced as `compiling` status, not a frozen call.
- 8 GB memory pressure → worker may be jetsam-killed mid-run → client treats it as a retriable worker-interruption, not a crash of the host ([gotcha #2,#3]).
- Empty/zero-length or unreadable audio → invalid-input error before loading any model.
- Vocabulary longer than the prompt budget → truncate to fit ~224 tokens, deterministically.

### 1.5 Out of scope (Part 1)

Persistence (that's `TranscriptionService`/DataStore in later projects), vocab *assembly/source-of-truth* (Vocabulary module later), the audio *capture* itself (Part 2), "me"/cross-file speaker identity (P2), and any UI beyond the CLI.

---

## Part 2 — Audio Capture Library

### 2.1 Purpose

The low-level systems engine for capturing and monitoring macOS audio. No app or data knowledge. Productionizes `experiments/AudioLab` (Core Audio process taps + `AVAudioEngine`, RMS monitor, encoder settings, recording coordinator, process monitor).

### 2.2 Features & behaviors

- **Two-stream capture.** Mic via `AVAudioEngine` input-node tap; **global** system audio via Core Audio process tap + aggregate device (global, not per-process — per [Phase 9 validation](../../../research/audio/phase9_validation_findings.md), per-process capture was dropped; global also sidesteps the Teams silent-capture issue). Two independent mono streams, each to its own file, sharing a start reference timestamp for later alignment. The caller provides the write paths (the library does **not** choose storage locations).
- **Crash-safe write, then repackage.** Record **PCM into CAF** during capture (CAF+AAC is *not* crash-safe — AAC needs a `pakt` chunk written only on close), then on stop **encode to AAC `.m4a`** for long-term storage ([finding #5](../../../research/audio/phase9_validation_findings.md)). Storage format: **ADTS AAC-LC, mono, 24 kHz, 64 kbps** (24 kHz covers the 16 kHz STT models with headroom). A partially written CAF remains decodable up to the last frame after a crash.
- **Route-change survival (non-negotiable).** A meeting starting *is* a route change. Listen for default input/output device changes and Bluetooth state changes; tear down and rebuild the tap + aggregate device (output change) or restart the engine (input change) with a sub-second gap. **This is the headline reliability requirement for a meeting recorder.**
- **Per-process audio monitoring (detection signal only).** Observe `kAudioHardwarePropertyProcessObjectList` + per-process bundle ID / input-active / output-active as an **event stream**, for a later `MeetingDetection` module to match against a watchlist. Monitoring is per-process; **capture is global** — these are separate concerns.
- **Two-stream start alignment** and **zero-buffer detection scaffolding.** Keep the RMS health-monitor (`RMSMonitor` exists) in place but **leave it unwired** by default (the all-zero tap failure did not reproduce on macOS 15; wiring it is solving a non-problem — [Test 7](../../../research/audio/phase9_validation_findings.md)); expose it so it can be wired if the failure ever surfaces.
- **Permission-denial inference.** No public API checks system-audio permission status → on capture start, detect zero-filled buffers in the first ~2 s and report a probable missing grant (silence-detection pre-check, per [research](../../../research/permissions/README.md)); the library *reports* this — it does not own TCC prompts.

### 2.3 Contracts

- **In:** caller-provided write paths/URLs for the mic and system files; start/stop control; a selection of which signals to emit (capture, monitor, or both).
- **Out:** two finished `.m4a` files at the requested locations with a shared start timestamp; a live state surface (elapsed, levels) for UI; an async event stream for per-process audio activity; capture-failure / probable-permission-denied reports.
- **Errors:** capture-start-failed, tap/aggregate-device-failed, mic-engine-failed, conversion-failed (CAF retained as fallback), probable-permission-denied.

### 2.4 Edge cases

- Conversion CAF→M4A fails → keep the CAF (playable everywhere) and report; never lose audio.
- Device switch mid-capture → rebuild within sub-second; no crash, no permanent silence.
- Multi-output-device level attenuation → best-effort gain compensation by channel count ([§6b](../../../research/audio/README.md)); low priority.
- Microsoft Teams → covered by the global-tap default; ScreenCaptureKit fallback remains a documented contingency, **not built** in V1.

### 2.5 Out of scope (Part 2)

The data store, meeting *semantics*/watchlist matching (that's `MeetingDetection` later), stream **merging**/mixdown (that's Transcription, Part 1), choosing storage locations (the `Recording` service later), permission prompts/UI, the app-level recording lifecycle (`Recording` module later).

---

## Part 3 — Data Store

### 3.1 Purpose

The SwiftData persistence layer and single owner of persistent types. A module inside `BiscottiKit` (not its own package — idiomatic for SwiftData `@Model`; see [architecture §Granularity #3](../../../architecture.md)).

### 3.2 Features & behaviors

- **Schema.** `Meeting`/`Event` core; **versioned Transcript records** (multiple transcripts per meeting, each tagged with model version + created date); **audio-file references** (paths/bookmarks to the mic/system/merged files — the store holds references, not blobs); a **calendar-snapshot sub-item** that captures useful event fields and is **clearable in one operation** (survives the EventKit link breaking); **notes**; **settings**.
- **Container/config.** A configurable `ModelContainer` (on-disk for the app; **in-memory for tests**); a **sync-ready** configuration (CloudKit option wired but **off** — actual sync is Project 12). The store must be safe to construct against an in-memory container so the entire module unit-tests with no disk and no app.
- **CRUD, queries, utilities.** Create/read/update/delete; the common fetches the app will need (recent meetings, upcoming, by id).
- **Event ↔ recording association + correction.** Associate a recording with an event; **correct** a wrong association later.
- **Search (V1).** Simple SwiftData term matching across meeting title / people / transcript text. (FTS is a later polish.)
- **Transcript versioning semantics.** Adding a new transcript version never destroys prior versions; the "current"/preferred version is selectable.

### 3.3 Contracts

- **In:** `Sendable` DTOs from the engine packages (e.g. the Transcription `TranscriptResult`, Audio file references) — DataStore maps these into `@Model` types. It does **not** depend on EventKit/AudioCapture/Transcription internals; it stores their *results*.
- **Out:** model types + query results; an association API; search results.
- **Errors:** container-init-failed, save-failed, not-found, association-conflict.

### 3.4 Edge cases

- Orphaned audio references (file missing on disk) → represented as a recoverable/absent state, surfaced not crashed (real recovery flow is the `Recording` module later).
- Migration: schema is V1; design with a forward-compatible migration plan so later versions don't require a wipe. *(Migration on a real on-disk store is a thing unit tests with in-memory containers can't fully prove — but per the DataStore-tab decision it is **not** added to the Manual Test App; it is covered by the most realistic unit/integration tests we can write and revisited if a real migration lands.)*

### 3.5 Out of scope (Part 3)

EventKit/audio/transcription specifics, UI, networking, actual CloudKit sync (P2), the orphaned-recording *recovery flow* (Recording module, Project 4).

---

## Part 4 — Manual Test App

### 4.1 Purpose

A durable macOS app (`ManualTestApp/`, its own XcodeGen project at repo root, peer to `App/`) that makes the un-unit-testable behavior of the hardware/system libraries checkable by a human, with results recorded in the repo. It is **not** disposable (unlike `experiments/`); it is the permanent manual-test harness described in [`manual_test_app/project_overview.md`](../manual_test_app/project_overview.md).

It also **hosts the real `BiscottiTranscriber.xpc` service** (decided) so that Stage A retires the XPC + CoreML isolation risk end-to-end. The same `.xpc` is later reused by the main `App` (Project 4).

### 4.2 Features & behaviors

- **One tab per hardware/system library: Transcription and Audio Capture** (no DataStore tab — decided). Each tab codes the library's manual test plan as an **interactive, sequential script** of step types:
  - **Action button** — "Click to request permissions", "Click to start 15 s capture".
  - **Human question** — yes/no (+ optional note): "Did you see two permission dialogs (mic + system audio)?", "Did the mic stream capture your voice? Was quality acceptable?".
  - **Instruction** — "Speak and play system audio for the next 15 seconds", "Play these two files" (opens Finder / inline play buttons).
  - **Automated check** — runs in-app and self-reports: "two files exist at the right place, sizes reasonable", "transcript has ≥2 speakers and no segment past audio length".
- **Representative test scripts** (the actual content, drawn from the experiment `VALIDATION.md` files):
  - *Audio Capture:* permission prompts → timed two-stream capture → file-existence/size auto-check → play-back human check → route-change-mid-recording check (connect/disconnect AirPods) → monitoring shows the meeting app.
  - *Transcription:* model download w/ progress + disk check → **transcribe over the real XPC service** → diarized/sanitized output check (no past-audio segments) → **crash-isolation check** (kill the worker mid-run; host survives; retry succeeds) → custom-vocab bias spot-check.
- **Results persistence.** Each test has a stable id and a status of `pass` / `fail` / `not-run` (+ timestamp + optional note), saved to a **checked-in file in the repo** (a plist/JSON the app reads and writes). Re-running updates the entry.
- **CI gate (full infra — decided).** A CI check verifies **every** known test id is marked `run` (i.e. not `not-run`) in the results file. CI **cannot execute** the manual tests; it only verifies the file claims they were run. This is wired into the existing CI as a check.
- **CLAUDE.md staleness convention (decided).** Add the rule: *when an agent touches `Transcription` or `AudioCapture`, mark that library's manual tests `not-run`* (needs re-review), so the human knows to re-run them. The CI gate then forces them to be re-run before the results file is "all-run" again.

### 4.3 Contracts & constraints

- The app depends on the three libraries through their **tight public APIs only** — building it is itself a test that those APIs are usable from a real app target. (Per the manual-test philosophy: "put the hard thing under a really tight API defining what the app needs.")
- The app builds via the **non-gating app tier** (`make build-app` / `mcp__hooks-mcp__build_app`) — it needs `xcodebuild` + the XPC bundle, so it cannot be a `swift test` package. **Its build must be green automatically; only its *execution* needs a human.**
- Testability seam: the **interactive scripts and the results-file read/write/serialization live in a `swift test`-able module** (in `BiscottiKit`, e.g. a small `ManualTestKit`/results model), so the harness logic is unit-tested even though the app shell and live runs are not.

### 4.4 Out of scope (Part 4)

Automating the human checks; testing libraries that are fully unit-testable (DataStore); shipping/signing the test app; any product UI (it is a utilitarian harness).

---

## Cross-cutting

- **Testability seam (the whole point).** Each library is built so the overwhelming majority runs under `swift test`: Core Audio / AVAudioEngine / EventKit / WhisperKit / TCC live behind seams; tests feed synthetic buffers, stubbed engine clients, fixture audio clips, and in-memory containers. The repo `architecture.md` "Tested by" lines are the contract.
- **Logging.** Each component uses `os.Logger` with its own subsystem/category; diagnostics to unified logging, never stdout (except the CLI's JSON-to-stdout/diagnostics-to-stderr split).
- **Error surfacing.** No silent failures, especially in capture and transcription; errors propagate to a caller-facing surface (return value / typed error / event), ready for a UI later.
- **Strictness.** Swift 6 language mode + warnings-as-errors, matching the scaffolding bar. New packages follow `BiscottiKit`'s manifest conventions (the `Transcription` package pins `argmax-oss-swift` and may need `swift-tools-version: 6.0` like the experiment; `AudioCapture` matches BiscottiKit).
- **Automated checks each phase.** Every phase ends green on `lint` + `test` (+ `build_app` where the app target is touched), run via `hooks-mcp` (Bash sandbox cannot compile Swift — see root `CLAUDE.md`).

## Definition of done

1. `Transcription` and `AudioCapture` exist as their own packages with the full public APIs from their component docs, unit/integration-tested with seams + fixtures, each green under `swift test`; Transcription ships its CLI harness.
2. `DataStore` exists as a `BiscottiKit` module, fully unit-tested against an in-memory container.
3. The `ManualTestApp` builds (app tier, green automatically), hosts the real `BiscottiTranscriber.xpc`, and presents interactive Transcription + Audio Capture test scripts that read/write the checked-in results file; the results-file logic is unit-tested; CI gates on "all tests marked run"; CLAUDE.md carries the staleness convention.
4. The implementation plan reaches its final phase fully green on automated checks, with the **only** human step being the last phase: run the Manual Test App and record pass/fail.

## Out of scope (whole project)

Re-deriving any settled `research/` decision; any later-project component (Recording, MeetingDetection, TranscriptionService, Calendar, the UI screens, the main App composition); signing/notarization (Project 9); "me"/cross-file speaker identity (P2); CloudKit sync (P12); FTS search.
</content>
