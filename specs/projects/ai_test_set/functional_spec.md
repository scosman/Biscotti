---
status: complete
---

# Functional Spec: A.5 — AI Test Set & Manual Test App Updates

## 0. Summary

Three coupled deliverables:

1. **AI test set** — a new category of automated tests that are real (CLI-runnable, not manual) but heavy (download GB of models, slow), isolated so they do **not** run on every `make test`, with their own `make test-ai` target. No CI wiring.
2. **Diarization made tunable + a correctness test** — the pipeline reports **1 speaker** for a known **3-speaker** reference clip when run with SDK defaults. Rather than change production, we expose an **optional, test-only diarization-threshold knob**; the AI test passes a tuned threshold and asserts the pipeline then separates the 3 speakers and transcribes each accurately. **Production stays on SDK defaults.**
3. **Manual Test App updates** — the transcription tab's quality checks are **cut** (the `make test-ai` AI test covers them better and they'd be duplicative); it keeps the model-download steps + a "did `make test-ai` pass?" tracker. The audio-capture tab gains the expanded scenario cases.

Two reference clips back the **AI tests** (test target only): the 3-speaker clip (`mic.aac`/`system.aac` — diarization + transcript accuracy) and `custom_vocab_test.aac` (deliberately-hard terms — custom-vocabulary word match).

---

## 1. Reference clip & ground truth (shared foundation)

The audio at `ManualTestApp/Resources/mic.aac` + `system.aac` is **3 distinct human speakers**. We ran the pipeline and confirmed the transcript. This is the canonical ground truth used by both the AI test and the manual-test transcription tab.

### 1.1 Ground-truth transcript — three speaker chunks

The transcript, grouped into **speaker chunks** (maximal runs of the same speaker, in time order):

| Chunk | Speaker | Approx. window | Script (text) |
|---|---|---|---|
| 1 | A | 0.8–2.5 s | "Hello, this is a test of the system." |
| 2 | B | 4.5–8.0 s | "Hello, I am person number two. I am saying something back." |
| 3 | C | 9.7–13.0 s | "Hi, I'm person number three and you two are banana heads." |

- Chunk 2 spans two original utterances by the **same** speaker (B), concatenated.
- **Expected:** exactly **3 chunks**, **3 distinct speakers** (A, B, C all different), in this order.

### 1.2 Where it lives

The reference **audio**, the **chunked ground-truth scripts**, the chunk **count/distinctness**, and the **comparison logic** are used **only by the AI tests** (the manual app no longer transcribes these clips). They live in the `TranscriptionTests` target: clips in `Fixtures/`, utilities + ground truth + evaluators as `internal` test code (architecture §2). No public API on `Transcription` and no shared module are needed; the clips are a single copy in the test fixtures.

### 1.3 Chunking + comparison contract

The shared utility provides:

- **Chunk building** — given a `TranscriptResult`, order segments by start time and **merge adjacent segments that share the same `speakerID`** into chunks. Each chunk has: the speaker ID, the start/end span, and the concatenated text (segment texts joined by single spaces).
- **Normalization** — lowercase; trim; collapse internal whitespace to single spaces; strip punctuation (`. , ! ? ' " : ;`). Applied to chunk text and ground-truth script before distance.
- **Levenshtein distance** — character-level edit distance; **normalized ratio** = `distance / max(len(a), len(b))`.
- **Match predicate** — `ratio <= tolerance`, default tolerance **0.05** (tight — the ground truth is the model's own confirmed output, so this allows only minor nondeterminism).

The chunk-based correctness check (used by both the AI test and the manual tab):

1. **Chunk count == 3.**
2. **All 3 chunk speaker IDs are distinct** (so the structure is A/B/C, not e.g. A/B/A).
3. **Per-chunk Levenshtein** — chunk *i*'s normalized text vs. ground-truth chunk *i*'s script, each `<= 0.05`, matched in order. On failure, report which chunk and the actual ratio + both strings.

If (1) fails, (3) cannot align and the check fails at (1) with the observed chunk count/speakers reported.

### 1.4 Second reference clip — custom vocabulary

`ManualTestApp/Resources/custom_vocab_test.aac` is a single clip of one voice reading a list of deliberately-hard terms. The spoken **script** and the **custom-vocabulary list** are the same 10 terms:

> NASA, Kubernetes, Postgres, Qwen, Mistral, Llama, Croissant, gnocci, Paella, Facade

Base Whisper mis-spells several of these without biasing; applying them as `customVocabulary` should make them transcribe correctly. ("gnocci" is intentionally the user's spelling — the vocab term and the expected match target are both `gnocci`.)

**Single-file handling:** this is one mono track (no separate system audio). The pipeline's `processAudio(mic:system:)` requires both paths, so the test passes `custom_vocab_test.aac` as **both** `mic` and `system` (the merge sums identical content → same speech; diarization is **not** asserted for this clip).

**Word-match contract** (distinct from the chunk/Levenshtein contract — Levenshtein is too lenient for single-word correctness):

- Take the with-vocab transcript's full text; split into words on whitespace.
- Normalize each word: strip leading/trailing punctuation, lowercase.
- Build the set of normalized transcript words.
- Expected set (normalized): `nasa, kubernetes, postgres, qwen, mistral, llama, croissant, gnocci, paella, facade`.
- A term **matches** iff it is an exact member of the transcript word set.
- **Gating assertion:** with vocab applied, **all 10** expected terms match. Report any misses. (Documented fallback: if one term proves stubborn even with vocab, relax to a documented `N/10` bar — but the target is 10/10, since "if it works with vocab, it's good.")

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

`processAudio(mic:system:)` on the 3-speaker clip, **passing the tuned diarization threshold** (the test-only knob, §3), then assert against the shared ground truth (§1.3):

1. **Chunk count == 3** (hard).
2. **3 distinct chunk speakers** (hard).
3. **Per-chunk Levenshtein ≤ 0.05** for each of the 3 chunks (hard).
4. **No hallucination** — no segment's `endTime` exceeds the actual audio duration (retained; validates the `TranscriptSanitizer` clamp).

> The threshold the test passes is determined empirically (§3.4) and is a **test constant** — production does not pass it.

#### 2.4.2 Custom-vocabulary word match (`custom_vocab_test.aac`)

`processAudio(mic:system:customVocabulary:)` with the clip as both streams (§1.4) and the 10-term vocab list, then assert via the **word-match contract** (§1.4):

5. **All 10 expected terms present** as exact normalized word matches (hard; documented `N/10` fallback). Failure detail lists the misses.

This test does **not** pass a diarization threshold (diarization isn't asserted here). It deliberately uses one `processAudio` call **with** vocab — a without-vocab control run is not required for the gate (it's a soft-bias effect; we assert the with-vocab outcome the user confirmed works).

Each test = one model load → one `processAudio` call → assertions read its `TranscriptResult`, to keep cost down.

### 2.5 First-run / environment behavior

- On first `make test-ai`, models download to the shared cache (`~/Library/Application Support/Biscotti`, per `ModelStorage`). Subsequent runs are fast (OS-compiled model cache).
- If models are absent and the machine is offline, the AI test **fails with a clear "models unavailable / offline" message** — it does not hang or silently pass. (Download is the pipeline's responsibility on demand.)
- Intended for developer machines only; **not** wired into any CI tier.

### 2.6 Execution constraint (important for planning)

The coding agent **cannot run `make test-ai` itself** — it compiles Swift and downloads models, neither of which works in the agent's sandbox, and there is no `hooks-mcp` tool for it. Therefore:

- Each iteration that depends on running the heavy pipeline requires a **human run** of `make test-ai` (or the diagnostic CLI) — e.g. the user runs it via the `!` prefix — and reports results back.
- To minimize round-trips, the implementation provides a **diagnostic affordance** (§3.4) so a single human run reveals the threshold that yields the correct chunking, rather than many guess-and-check cycles.

---

## 3. Part 2 — Diarization: make it tunable (production unchanged)

### 3.1 The behavior

`InProcessTranscriptionEngine.runDiarization` calls `speakerKit.diarize(audioArray:)` with **no options** (SDK defaults `numberOfSpeakers = nil`, `clusterDistanceThreshold = 0.6`). On short audio with brief utterances, the SDK's internal `minActiveRatio` (0.2) filter discards most embeddings and hierarchical clustering merges everything below the 0.6 cut → **1 cluster**. STT itself is accurate; the merged mic+system mono is fine.

### 3.2 Decision: do not change production

Production keeps SDK defaults (single global threshold of 0.6, auto-detect). Lowering the threshold globally risks **over-splitting** one speaker into many on real meetings, and we have only one reference clip — not enough to justify a production change. Instead we make the threshold **tunable per call** and use that only in tests.

### 3.3 The optional, test-only knob

Add an **optional diarization-threshold parameter** (e.g. `clusterDistanceThreshold: Float? = nil`, or a tiny `DiarizationTuning` value) threaded through:

- `Transcriber.processAudio(...)` (public API) — default `nil`.
- `TranscriptionEngine.processAudio(...)` and `InProcessTranscriptionEngine` → mapped to `PyannoteDiarizationOptions(clusterDistanceThreshold:)` when non-nil; when nil, call `diarize` exactly as today (defaults).
- The **XPC path** (`XPCProcessRequest` + the `BiscottiTranscriber` service) — for protocol completeness; no consumer passes a non-nil value today (the Manual Test App no longer transcribes).
- The CLI (`--diarization-threshold <Float>`), for the diagnostic run.

**Default `nil` everywhere ⇒ production behavior is byte-for-byte unchanged.** Only the AI test + CLI diagnostic pass a value.

`numberOfSpeakers` is **not** exposed (deferred). The knob is the cluster-distance threshold only.

### 3.4 Diagnostic affordance (to cut human round-trips)

The CLI gains `--diarization-threshold <Float>` (and may print the resulting chunking/speaker count). Optionally a tiny sweep mode prints `chunk count` for a set of candidate thresholds on the reference clip. The user runs it once; we read off the threshold that yields exactly 3 distinct chunks matching the ground truth, and bake that value in as the **test constant**. This is a developer/diagnostic affordance, not a production API.

### 3.5 Acceptance

- With `--diarization-threshold` / the test constant applied, the AI test §2.4 assertions 1–3 pass on the reference clip.
- With **no** threshold passed (production path), behavior is unchanged from today (no regression to existing unit tests; `TranscriptSanitizer` behavior preserved).
- Documented: production still under-clusters very short clips by default; the knob + test exist to validate diarization correctness and to enable future tuning. This is an accepted, documented limitation, not a silent gap.

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
- **Changing production diarization defaults** — explicitly out; the knob is test-only.
- Exposing `numberOfSpeakers` / centroid embeddings / cross-file speaker ID (Projects 11) — deferred.
- A larger reference-audio corpus beyond the two clips — recommended later.
- **Any CI wiring for the AI tests** — developer-run via `make test-ai` only.
- Changes to the Audio Capture *recording* implementation beyond the manual-test scripts.

---

## 6. Resolved decisions & required input

Resolved (this round):

1. Diarization threshold is an **optional, test-only** parameter; **production stays on SDK defaults**. `numberOfSpeakers` deferred.
2. **`make test-ai` only — no CI.**
3. Levenshtein tolerance **0.05**, applied **per speaker chunk**. Diarization correctness = **chunk count == 3 + 3 distinct speakers + per-chunk LD** (no separate partition check).
4. Custom-vocab uses `custom_vocab_test.aac` (provided) with an **automated word-match** AI test (§2.4.2) — per the word-split / exact-match recipe; not a manual step.
5. **Reset all manual results to `not-run`.**
6. The manual app's **transcription quality + XPC crash steps are cut**; the transcription tab = model-download steps + a `make test-ai` tracker. Clips + evaluators live only in the test target (no shared module, no dupe clips, no XPC threshold passed).

**Required input — satisfied.** All reference clips are provided (`mic.aac`, `system.aac`, `custom_vocab_test.aac`) and will be relocated to `Tests/TranscriptionTests/Fixtures/` (their single home). The only value still to be determined empirically is the **tuned diarization threshold**, via the §3.4 diagnostic run during implementation (one human CLI run).
