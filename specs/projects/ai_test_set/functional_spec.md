---
status: complete
---

# Functional Spec: A.5 — AI Test Set & Manual Test App Updates

## 0. Summary

Three coupled deliverables:

1. **AI test set** — a new category of automated tests that are real (CLI-runnable, not manual) but heavy (download GB of models, slow), isolated so they do **not** run on every `make test`, with their own `make test-ai` target. No CI wiring.
2. **Diarization correctness test** — the re-recorded reference clip diarizes to **3 distinct speakers under production defaults** (SDK defaults, no override). The AI test asserts speaker separation + transcript accuracy with **no** diarization override. A test-only tuning knob is **deferred** (the original short clip collapsed to 1 speaker, but the re-recorded clip with longer, more distinct turns no longer needs one). **Production stays on SDK defaults, unchanged.**
3. **Manual Test App updates** — the transcription tab's quality checks are **cut** (the `make test-ai` AI test covers them better and they'd be duplicative); it keeps the model-download steps + a "did `make test-ai` pass?" tracker. The audio-capture tab gains the expanded scenario cases.

Two reference clips back the **AI tests** (test target only): the 3-speaker clip (`mic.aac`/`system.aac` — diarization + transcript accuracy) and `custom_vocab_test.aac` (deliberately-hard terms — custom-vocabulary word match).

---

## 1. Reference clip & ground truth (shared foundation)

The audio at `ManualTestApp/Resources/mic.aac` + `system.aac` is **3 distinct human speakers**. We ran the pipeline and confirmed the transcript. This is the canonical ground truth used by both the AI test and the manual-test transcription tab.

### 1.1 Ground-truth transcript — nine segments, five chunks, three speakers

The raw time-ordered segments from the reference clip:

| Seg | Time window | Speaker | Text |
|---|---|---|---|
| 1 | 0.0–2.0 s | 0 | "This is a thing we actually need to do that's important." |
| 2 | 2.5–6.8 s | 0 | "I'm going to talk for a second and then I'm going to hand it over to James who's going to say something regular and not in a weird voice." |
| 3 | 8.2–8.5 s | 1 | "Banana," |
| 4 | 8.9–9.2 s | 1 | "banana." |
| 5 | 10.5–11.2 s | 0 | "Say something for real James." |
| 6 | 12.7–14.3 s | 1 | "Okay, fine my banana head." |
| 7 | 17.0–18.5 s | 2 | "And what would you like me to say?" |
| 8 | 19.5–20.4 s | 2 | "Anything at all." |
| 9 | 21.3–22.7 s | 2 | "I would like more food please." |

The speaker sequence is `0,0,1,1,0,1,2,2,2`. Merging adjacent same-speaker segments (the `TranscriptChunker` adjacency-merge logic) yields **5 chunks** across **3 distinct speakers**, with the interleaved equivalence pattern **[A, B, A, B, C]**:

| Chunk | Speaker label | Script (merged text) |
|---|---|---|
| 1 | A | "This is a thing we actually need to do that's important. I'm going to talk for a second and then I'm going to hand it over to James who's going to say something regular and not in a weird voice." |
| 2 | B | "Banana, banana." |
| 3 | A | "Say something for real James." |
| 4 | B | "Okay, fine my banana head." |
| 5 | C | "And what would you like me to say? Anything at all. I would like more food please." |

- **Expected:** exactly **5 chunks**, **3 distinct speakers**, with the canonical first-occurrence speaker pattern `[0,1,0,1,2]` (i.e. the interleaving structure `[A,B,A,B,C]`).

### 1.2 Where it lives

The reference **audio**, the **chunked ground-truth scripts**, the chunk **count/distinctness**, and the **comparison logic** are used **only by the AI tests** (the manual app no longer transcribes these clips). They live in the `TranscriptionTests` target: clips in `Fixtures/`, utilities + ground truth + evaluators as `internal` test code (architecture §2). No public API on `Transcription` and no shared module are needed; the clips are a single copy in the test fixtures.

### 1.3 Chunking + comparison contract

The shared utility provides:

- **Chunk building** — given a `TranscriptResult`, order segments by start time and **merge adjacent segments that share the same `speakerID`** into chunks. Each chunk has: the speaker ID, the start/end span, and the concatenated text (segment texts joined by single spaces).
- **Normalization** — lowercase; trim; collapse internal whitespace to single spaces; strip punctuation (`. , ! ? ' " : ;`). Applied to chunk text and ground-truth script before distance.
- **Levenshtein distance** — character-level edit distance; **normalized ratio** = `distance / max(len(a), len(b))`.
- **Match predicate** — `ratio <= tolerance`, default tolerance **0.05** (tight — the ground truth is the model's own confirmed output, so this allows only minor nondeterminism).

The chunk-based correctness check (used by both the AI test and the manual tab):

1. **Chunk count == 5** (after adjacency merge).
2. **Speaker-equivalence pattern matches `[A,B,A,B,C]`** — compute a canonical first-occurrence index sequence from the actual chunks' speaker IDs (e.g. IDs `[7,3,7,3,9]` → `[0,1,0,1,2]`) and from the reference labels, and require them equal. This single check enforces chunk count, 3 distinct speakers, and the correct interleaving structure.
3. **Per-chunk Levenshtein** — chunk *i*'s normalized text vs. ground-truth chunk *i*'s script, each `<= 0.05`, matched in order. On failure, report which chunk, the actual ratio, and both strings.

If (1) fails, (3) cannot align and the check fails at (1) with the observed chunk count/speakers reported. On pattern mismatch, report the observed vs. expected canonical pattern and the observed distinct-speaker count.

### 1.4 Second reference clip — custom vocabulary

`Tests/TranscriptionTests/Fixtures/custom_vocab_test.aac` is a single clip of one voice reading a list of deliberately-hard terms. The clip contains all 10 terms (nasa, kubernetes, postgres, qwen, mistral, llama, croissant, gnocci, paella, facade) and the test uses the full list.

> **Test currently disabled.** WhisperKit's `promptTokens` API silently blanks the entire transcript for certain term combinations — this affects both turbo and non-turbo models. The custom-vocab AI test is skipped (`.disabled`) pending an upstream SDK fix: [argmax-oss-swift#489](https://github.com/argmaxinc/argmax-oss-swift/issues/489), [argmax-oss-swift#428](https://github.com/argmaxinc/argmax-oss-swift/pull/428).

**Single-file handling:** this is one mono track (no separate system audio). The pipeline's `processAudio(mic:system:)` requires both paths, so the test passes `custom_vocab_test.aac` as **both** `mic` and `system` (the merge sums identical content → same speech; diarization is **not** asserted for this clip).

**Word-match contract** (distinct from the chunk/Levenshtein contract — Levenshtein is too lenient for single-word correctness):

- Take the with-vocab transcript's full text; split into words on whitespace.
- Normalize each word: strip leading/trailing punctuation, lowercase.
- Build the set of normalized transcript words.
- Expected set (normalized): `nasa, kubernetes, postgres, qwen, mistral, llama, croissant, gnocci, paella, facade`.
- A term **matches** iff it is an exact member of the transcript word set.
- **Gating assertion:** with vocab applied, **all 10** expected terms match (10/10). Report any misses. *(Test currently disabled — see note above.)*

---

## 2. Part 1 — AI test set

### 2.1 What qualifies as an "AI test"

A test that requires downloading model weights and/or running on-device ML inference (Whisper STT, SpeakerKit diarization, future LLM). Slow and bandwidth-heavy — must not run on every small commit — but **automated** (no human judgment) and CLI-runnable.

### 2.2 Isolation mechanism

- AI tests are **excluded by default** from `make test` (and therefore from `make ci` and `make precommit-checks`). "Excluded" means: under the default suite the AI tests do **no** model work — they are *skipped*, not merely fast.
- Mechanism (Swift Testing): a dedicated **tag** (e.g. `.aiModel`) for grouping/discoverability **plus** a **condition trait** keyed off an environment variable (e.g. `BISCOTTI_RUN_AI_TESTS`). Under plain `make test` the env var is unset → AI tests report as *skipped* (no download, no inference). The env-var gate is the reliable default-exclusion; the tag is for human/tooling filtering. (Exact trait wiring is an architecture detail.)
- Rationale for env-gate over name/`--filter` exclusion: version-robust, and guarantees the heavy work cannot run accidentally in the gating tier even if a test is invoked by name.

### 2.3 New `make` target

- `make test-ai` — runs the AI test set (sets the gate env var; runs the Transcription package tests, optionally filtered to the AI tag). The **only** sanctioned way to execute the heavy tests.
- **Not** part of `make test`, `make ci`, `make precommit-checks`, or `make manual-tests-check`. **No CI job** (per decision — developer-run only).
- Document `make test-ai` in `CLAUDE.md`'s Makefile table (non-gating, heavy) and in `make help`.

### 2.4 The Transcription AI tests

Both run the **in-process** pipeline (`Transcriber(backend: .inProcess)`), carry the `.aiModel` tag, and are env-gated (§2.2).

#### 2.4.1 Diarization + transcript accuracy (3-speaker clip)

`processAudio(mic:system:)` on the 3-speaker clip with **production defaults** (no diarization override), then assert against the shared ground truth (§1.3):

1. **Chunk count == 5** (hard; after adjacency merge).
2. **Speaker-equivalence pattern == `[0,1,0,1,2]`** (hard; enforces 3 distinct speakers + interleaving).
3. **Per-chunk Levenshtein ≤ 0.05** for each of the 5 chunks (hard).
4. **No hallucination** — no segment's `endTime` exceeds the actual audio duration (retained; validates the `TranscriptSanitizer` clamp).

> The re-recorded clip diarizes to 3 distinct speakers under production defaults, so the AI test passes **no** diarization override. Exposing a diarization tuning knob is deferred (§3); the test runs the production default path.

#### 2.4.2 Custom-vocabulary word match (`custom_vocab_test.aac`)

`processAudio(mic:system:customVocabulary:)` with the clip as both streams (§1.4) and the 10-term vocab list, then assert via the **word-match contract** (§1.4):

5. **All 10 expected terms present** (10/10) as exact normalized word matches (hard). Failure detail lists the misses and the full transcript text. *(Test currently disabled — see §1.4 note.)*

This test does **not** pass a diarization threshold (diarization isn't asserted here). It deliberately uses one `processAudio` call **with** vocab — a without-vocab control run is not required for the gate (it's a soft-bias effect; we assert the with-vocab outcome the user confirmed works).

Each test = one model load → one `processAudio` call → assertions read its `TranscriptResult`, to keep cost down.

### 2.5 First-run / environment behavior

- On first `make test-ai`, models download to the shared cache (`~/Library/Application Support/Biscotti`, per `ModelStorage`). Subsequent runs are fast (OS-compiled model cache).
- If models are absent and the machine is offline, the AI test **fails with a clear "models unavailable / offline" message** — it does not hang or silently pass. (Download is the pipeline's responsibility on demand.)
- Intended for developer machines only; **not** wired into any CI tier.

### 2.6 Execution constraint (important for planning)

The coding agent **cannot run `make test-ai` itself** — it compiles Swift and downloads models, neither of which works in the agent's sandbox, and there is no `hooks-mcp` tool for it. Therefore:

- Each iteration that depends on running the heavy pipeline requires a **human run** of `make test-ai` — e.g. the user runs it via the `!` prefix — and reports results back. No CLI diagnostic is needed this round (the re-recorded clip diarizes correctly under defaults).

---

## 3. Diarization: production unchanged (tuning knob deferred)

### 3.1 The behavior

`InProcessTranscriptionEngine.runDiarization` calls `speakerKit.diarize(audioArray:)` with **no options** (SDK defaults `numberOfSpeakers = nil`, `clusterDistanceThreshold = 0.6`). The original short clip with very brief utterances collapsed to 1 speaker under these defaults (the SDK's `minActiveRatio` filter discarded most embeddings). The **re-recorded clip** with longer, more distinct turns diarizes correctly to 3 speakers under production defaults — the collapse is no longer observed.

### 3.2 Decision: production unchanged, no knob this round

Production keeps SDK defaults. The re-recorded clip diarizes to 3 distinct speakers without any override, so a tuning knob is unnecessary this round. No `clusterDistanceThreshold` or `numberOfSpeakers` parameter is added.

### 3.3 DEFERRED — diarization tuning parameter

The early plan exposed an optional `clusterDistanceThreshold: Float?` parameter threaded through the public API, engine protocol, XPC request, and CLI. This was implemented briefly (commit `d8cdd21`) and **reverted** (`9febe90`) once the re-recorded clip proved it unnecessary.

If diarization tuning is ever needed (e.g. for very short clips with brief utterances that under-cluster), `numberOfSpeakers` would be the **more direct lever** than `clusterDistanceThreshold`: SpeakerKit's VBx refinement step can override the AHC seed clustering, making the distance threshold unreliable for controlling speaker count on short clips. Exposing either parameter is deferred to a future project.

### 3.4 Acceptance

- With **production defaults** (no diarization override), the AI test §2.4.1 assertions 1–4 pass on the re-recorded reference clip: 5 chunks, 3 distinct speakers, correct interleaving pattern, per-chunk LD within tolerance.
- No diarization tuning parameter exists in the public API, engine protocol, CLI, or XPC request.
- Documented: very short clips with brief utterances may still under-cluster under SDK defaults; a future project can expose `numberOfSpeakers` if needed. The re-recorded reference clip (with longer, more distinct turns) does not exhibit this issue.

---

## 4. Part 3 — Manual Test App updates

### 4.1 Transcription tab — reduced to download + AI-test tracker

The transcription tab's quality/diarization/vocab checks are **cut** — `make test-ai` (§2.4) covers them better, so the in-app versions were duplicative. The **XPC crash-isolation** steps are also cut (keeping them would re-couple the tab to a live capture, which we don't want). This removes all in-app transcription of reference clips: no bundled clips, no shared evaluator code, no threshold over the XPC boundary. What remains:

- the existing **model-download / cache** steps (still validate the app's download UX); and
- a new **`tx_ai_test_passed`** humanQuestion: "Run `make test-ai` … did all AI tests pass?" — so the AI-test outcome is tracked in `manual_test_results.json` like every other step.

The Audio Capture tab is unchanged in purpose (still records live) and gains the expanded cases in §4.3.

### 4.2 Transcription tab — final steps

| Step ID | Type | Note |
|---|---|---|
| `tx_clear_cache` | action | unchanged |
| `tx_model_download` | action | unchanged |
| `tx_model_disk` | humanQuestion | unchanged |
| `tx_ai_test_passed` | humanQuestion | **NEW** — "Run `make test-ai`; did all AI tests pass?" |

Removed: `tx_transcribe`, `tx_speakers`, `tx_no_hallucination`, `tx_custom_vocab`, and the crash steps `tx_crash_setup` / `tx_crash_host_survives` / `tx_crash_retry`.

### 4.3 Audio Capture tab — expanded cases

Replace one-off "FaceTime"/"Zoom/Meet/Teams" examples with **Google Meet**, with the rationale that an "instant meeting" (meet.google.com → New meeting → Start an instant meeting) needs only one participant, so it's trivial to set up — unlike a FaceTime call that waits for a real callee.

Keep existing steps (permissions, timed capture, start/stop, files-exist, mic/system playback, monitoring, crash safety). Add/clarify:

- **`ac_route_change` (AirPods transfer)** — rewrite: "Mid-recording, connect AirPods, speak, then disconnect and keep speaking. In playback you should *hear the mic source change* (built-in → AirPods → built-in); capture survives the transitions without crash or silence."
- **`ac_meet_close_midcapture`** — NEW. "Start capture with a Google Meet instant meeting already running; speak; after a few seconds close Meet and keep speaking. Verify (mic playback) your voice was captured **both before and after** Meet closed."
- **`ac_meet_open_midcapture`** — NEW. "Start capture with **no** meeting running; speak; after a few seconds start a Google Meet instant meeting and keep speaking. Verify your voice was captured **both before and after** Meet started."
- **`ac_mega_experiment`** — NEW (instruction + two questions). Sequence: (1) start capture; (2) start a Google Meet instant meeting; (3) open Music and play a track, saying "starting music now" exactly as it begins; (4) insert AirPods; (5) remove AirPods; (6) stop the Meet; (7) stop capture.
  - Question A (voice continuity): "In the mic playback, is your voice clear and continuous across **all** mode changes (built-in → AirPods → built-in, Meet on/off)?"
  - Question B (system timing): "In the system playback, does the music begin **exactly** when you said 'starting music now' — i.e. system audio is time-aligned to the mic with no offset?"
- **`ac_monitoring`** — reword to Google Meet: "Start a Google Meet instant meeting. Does monitoring list the browser/Meet as an active audio source?"

New step IDs (`ac_meet_close_midcapture`, `ac_meet_open_midcapture`, `ac_mega_experiment` + its question id(s)) are added to the canonical script and to the results file as `not-run`.

### 4.4 Instruction clarity fixes

- **Process-kill step** (`ac_crash_safety_setup`) — name the exact process and give both methods: "In Activity Monitor, select **ManualTestApp** and Force Quit; or run `kill -9 $(pgrep -x ManualTestApp)`."
- The transcription crash-isolation steps (`tx_crash_*`) are **removed** (§4.1), so their process-naming fix is moot. Custom-vocab is now an **AI test** (§2.4.2), not a manual step.

### 4.5 Results file & `manual-tests-check` impact

- This project touches `Packages/Transcription` and restructures the manual scripts, so per the repo's manual-test staleness rule **all** affected manual results reset to `not-run`, and the results JSON is regenerated to contain every current step ID (the new `ac_*` steps and the reduced `tx_*` set) as `not-run`; stale keys for cut `tx_*` steps are dropped.
- Consequence: `make manual-tests-check` (and its non-gating CI job) stays **RED** until a human re-runs on real Apple-silicon hardware — the already-expected Phase-4.5 state. No gating tier affected.

---

## 5. Out of scope

- LLM/intelligence AI tests (Project 10) — the AI-test *category* is built to host them later, but none are added now.
- AudioCapture automated/AI tests — the AI test set targets Transcription only this round.
- **In-app transcription quality + XPC crash-isolation manual tests** — removed (the AI test covers quality; crash isolation is dropped, not replaced).
- **A test-only diarization tuning knob** — deferred (the re-recorded clip diarizes correctly under production defaults; no knob needed).
- Exposing `numberOfSpeakers` / centroid embeddings / cross-file speaker ID (Projects 11) — deferred.
- A larger reference-audio corpus beyond the two clips — recommended later.
- **Any CI wiring for the AI tests** — developer-run via `make test-ai` only.
- Changes to the Audio Capture *recording* implementation beyond the manual-test scripts.

---

## 6. Resolved decisions & required input

Resolved (this round):

1. **Production stays on SDK defaults; no test-only diarization tuning knob this round (deferred).** `numberOfSpeakers` / `clusterDistanceThreshold` exposure deferred to a future project.
2. **`make test-ai` only — no CI.**
3. Levenshtein tolerance **0.05**, applied **per speaker chunk**. Diarization correctness = **chunk count == 5 + speaker-equivalence pattern [A,B,A,B,C] (enforces 3 distinct speakers + interleaving) + per-chunk LD ≤ 0.05**.
4. Custom-vocab uses `custom_vocab_test.aac` (provided) with an **automated word-match** AI test (§2.4.2) — per the word-split / exact-match recipe; not a manual step.
5. **Reset all manual results to `not-run`.**
6. The manual app's **transcription quality + XPC crash steps are cut**; the transcription tab = model-download steps + a `make test-ai` tracker. Clips + evaluators live only in the test target (no shared module, no dupe clips, no XPC threshold passed).

**Required input — satisfied.** All reference clips are provided (`mic.aac`, `system.aac`, `custom_vocab_test.aac`) and will be relocated to `Tests/TranscriptionTests/Fixtures/` (their single home). No empirical threshold needs determining — the re-recorded clip diarizes to 3 speakers under production defaults. The `make test-ai` run validates diarization under defaults.
