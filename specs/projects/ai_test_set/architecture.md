---
status: complete
---

# Architecture: A.5 — AI Test Set & Manual Test App Updates

Single-file architecture (medium project). No `components/` docs.

> **Scope note (revised):** the Manual Test App's *transcription* checks (quality **and** XPC crash-isolation) are **cut** — quality is covered better by the `make test-ai` AI test, and keeping the crash test would re-couple transcription to a live capture (unwanted). Consequence: the comparison utilities + ground truth live **only in the test target** (no public API on `Transcription`, no shared module), the reference clips live **only in the test fixtures** (no dupe). The diarization tuning knob is **deferred** — there are no public API or CLI changes to the `Transcription` library (production unchanged, diarization runs under SDK defaults). The manual transcription tab keeps only the model-download steps + a "did `make test-ai` pass?" tracker.

## 0. Change map

| Area | Change |
|---|---|
| `Packages/Transcription` — library | **No public API changes.** Diarization tuning knob deferred; production unchanged. |
| `Packages/Transcription` — CLI | **No CLI changes.** `--diarization-threshold` / `--diarization-sweep` deferred. |
| `Packages/Transcription/Tests` | **All new test code lives here.** Comparison utilities + ground truth + evaluators (`internal` to the test target), the 3 `.aac` clips in `Fixtures/`, the env-gated `.aiModel` AI tests, and fast unit tests for the utilities. |
| `Packages/BiscottiKit` — `ManualTestKit` | `AudioCaptureScript.swift`: reword + add steps. `TranscriptionScript.swift`: **reduce** to download steps + a `make test-ai` tracker (cut quality **and** crash steps). |
| `ManualTestApp` | `WiredScripts.swift`: drop all transcription wiring except model download/cache; remove clip resolution + result holders. Remove the 3 `.aac` from `Resources/`. |
| `Makefile` | New `test-ai` target (env-gated, non-gating, no CI). |
| `CLAUDE.md` | Document `make test-ai`. |
| `ManualTestApp/Results/manual_test_results.json` | Regenerate with every current step ID = `not-run`. |
| Audio assets | **Move** `mic.aac`, `system.aac`, `custom_vocab_test.aac` from `ManualTestApp/Resources/` → `Tests/TranscriptionTests/Fixtures/` (single home; no dupe). |

Production targets (`App/`, `Biscotti`) are untouched — no new code, no API changes.

---

## 1. Diarization — production unchanged (tuning deferred)

`runDiarization` is called with no options, exactly as today — SDK defaults (`numberOfSpeakers = nil`, `clusterDistanceThreshold = 0.6`). The re-recorded reference clip diarizes to 3 distinct speakers under these defaults.

The planned threshold plumbing (optional `diarizationClusterThreshold: Float?` through `Transcriber` → `TranscriptionEngine` → `InProcessTranscriptionEngine` → `XPCProcessRequest`) and CLI diagnostics (`--diarization-threshold`, `--diarization-sweep`) were implemented briefly and **reverted**. No public API, engine protocol, XPC request, or CLI changes exist.

**Deferred future work:** if diarization tuning is ever needed, `numberOfSpeakers` is the more direct lever than `clusterDistanceThreshold` — SpeakerKit's VBx refinement step can override the AHC seed clustering, making the distance threshold unreliable for controlling speaker count on short clips.

---

## 2. Comparison support — inside the **test target** (`TranscriptionTests`)

All `internal` to the test target (only the tests consume them). `import Transcription` for the public `TranscriptResult` types; no `@testable` needed.

### 2.1 Utilities

```swift
enum TextNormalize {
    static func normalize(_ s: String) -> String      // lowercase, trim, collapse ws, strip . , ! ? ' " : ;
    static func words(_ s: String) -> [String]
}
enum Levenshtein {
    static func distance(_ a: String, _ b: String) -> Int
    static func ratio(_ a: String, _ b: String) -> Double   // distance / max(count); 0 for two empties
}
struct TranscriptChunk: Equatable { let speakerID: Int?; let text: String; let start, end: TimeInterval }
enum TranscriptChunker {
    static func chunks(from result: TranscriptResult) -> [TranscriptChunk]  // merge adjacent equal-speakerID
}
enum WordMatch {
    static func evaluate(transcript: String, expected: [String]) -> (matched: [String], missed: [String])
}
```

### 2.2 Ground truth + evaluators

```swift
struct ReferenceChunk: Equatable { let speakerLabel: String; let script: String }

enum GroundTruth {
    static let chunks: [ReferenceChunk] = [
        .init(speakerLabel: "A", script: "This is a thing we actually need to do that's important. I'm going to talk for a second and then I'm going to hand it over to James who's going to say something regular and not in a weird voice."),
        .init(speakerLabel: "B", script: "Banana, banana."),
        .init(speakerLabel: "A", script: "Say something for real James."),
        .init(speakerLabel: "B", script: "Okay, fine my banana head."),
        .init(speakerLabel: "C", script: "And what would you like me to say? Anything at all. I would like more food please."),
    ]   // Pattern [A,B,A,B,C] — 5 chunks, 3 distinct speakers
    static let chunkLevenshteinTolerance = 0.05
    static let vocabTerms = ["NASA","Kubernetes","Postgres","Qwen","Mistral","Llama",
                             "Croissant","gnocci","Paella","Facade"]
}

struct ChunkEvaluation { let chunkCount, distinctSpeakers: Int; let perChunkRatios: [Double]
                         let passed: Bool; let detail: String }   // passed = count==5 && pattern==[0,1,0,1,2] && all ratio<=tol
enum DiarizationGroundTruth { static func evaluate(_ r: TranscriptResult) -> ChunkEvaluation }

struct VocabEvaluation { let matched, missed: [String]; let passed: Bool; let detail: String } // passed = missed.isEmpty
enum VocabGroundTruth { static func evaluate(_ r: TranscriptResult) -> VocabEvaluation }
```

### 2.3 Clip resolution

Clips live in `Tests/TranscriptionTests/Fixtures/` (`Package.swift` already `.copy("Fixtures")`). Resolve via `Bundle.module.url(forResource: "mic", withExtension: "aac", subdirectory: "Fixtures")`, etc.

---

## 3. AI tests + fast unit tests (`TranscriptionTests`)

### 3.1 Tag + gate

```swift
import Testing
extension Tag { @Tag static var aiModel: Self }
enum AITestGate { static var isEnabled: Bool { ProcessInfo.processInfo.environment["BISCOTTI_RUN_AI_TESTS"] == "1" } }
```

AI tests: `@Test(.tags(.aiModel), .enabled(if: AITestGate.isEnabled))` in `@Suite("AI model tests")`. Under plain `make test`, env var unset ⇒ skipped (no model work).

### 3.2 Diarization + accuracy (gated)

```swift
let mic = Bundle.module.url(forResource: "mic", withExtension: "aac", subdirectory: "Fixtures")!
let sys = Bundle.module.url(forResource: "system", withExtension: "aac", subdirectory: "Fixtures")!
let r = try await Transcriber(backend: .inProcess).processAudio(mic: mic, system: sys)
let e = DiarizationGroundTruth.evaluate(r)
#expect(e.passed, "\(e.detail)")
#expect(r.segments.allSatisfy { $0.endTime <= (try audioDuration(mic)) + 0.001 })  // no hallucination
```

### 3.3 Custom-vocab word match (gated)

```swift
let clip = Bundle.module.url(forResource: "custom_vocab_test", withExtension: "aac", subdirectory: "Fixtures")!
let r = try await Transcriber(backend: .inProcess).processAudio(
    mic: clip, system: clip, customVocabulary: GroundTruth.vocabTerms)   // single-track → both streams
#expect(VocabGroundTruth.evaluate(r).passed, "\(VocabGroundTruth.evaluate(r).detail)")  // 10/10
```

### 3.4 Failure / environment behavior

- Offline / models missing ⇒ pipeline throws `TranscriptionError.downloadFailed` ⇒ test fails with it surfaced (no hang/silent pass).
- chunk count ≠ 5 ⇒ `detail` reports observed count + per-chunk speaker IDs; ratios omitted.
- `speakerID == nil` segments form their own chunk ⇒ count/distinctness fails loudly.

### 3.5 Fast (non-AI) unit tests — gating tier

In the same target, no gate, no models:
- `Levenshtein`, `TextNormalize`, `TranscriptChunker` (same-speaker merge, A/B/A → 3 chunks/2 distinct, nil speaker), `WordMatch` (all/none/partial, punctuation, case).
- `DiarizationGroundTruth.evaluate` / `VocabGroundTruth.evaluate` on synthetic `TranscriptResult`s (pass + each failure mode: wrong chunk count, wrong speaker pattern, high Levenshtein).

The gated tests then only validate real model output.

---

## 4. Make target

```make
test-ai: ## NON-GATING: heavy AI/model tests (downloads GBs; not in CI)
	BISCOTTI_RUN_AI_TESTS=1 swift test --package-path Packages/Transcription
```

- Sets the gate env var; the package's fast tests also run (cheap). Optional `--filter "AI model tests"`.
- **Not** in `test`/`ci`/`precommit-checks`/`manual-tests-check`. **No CI job.**
- `CLAUDE.md` Makefile table gains a `test-ai` row (non-gating, heavy, developer-run; agent can't run it — a human runs it via `!`).

---

## 5. Manual Test App changes

### 5.1 `TranscriptionScript.swift` — reduced

Final steps (cut all quality + crash steps):

| ID | Type | Note |
|---|---|---|
| `tx_clear_cache` | action | unchanged (clears model cache) |
| `tx_model_download` | action | unchanged (download with status) |
| `tx_model_disk` | humanQuestion | unchanged (download status UX) |
| `tx_ai_test_passed` | humanQuestion | **NEW** — "Run `make test-ai` (downloads models; runs the automated transcription / diarization / custom-vocab quality tests). Did all AI tests pass?" |

Cut: `tx_transcribe`, `tx_speakers`, `tx_no_hallucination`, `tx_custom_vocab`, `tx_crash_setup`, `tx_crash_host_survives`, `tx_crash_retry`.

### 5.2 `AudioCaptureScript.swift` — expanded (unchanged from prior design)

| ID | Type | Note |
|---|---|---|
| `ac_request_permissions` | action | unchanged |
| `ac_two_dialogs` | humanQuestion | unchanged |
| `ac_timed_capture` | instruction | reworded; Google Meet instant meeting for system audio |
| `ac_start_recording` | action | unchanged |
| `ac_stop_recording` | action | unchanged |
| `ac_files_exist` | autoCheck | unchanged |
| `ac_playback_mic` | humanQuestion | unchanged |
| `ac_playback_system` | humanQuestion | unchanged |
| `ac_route_change` | humanQuestion | reworded → AirPods transfer (hear the mic source change) |
| `ac_meet_close_midcapture` | humanQuestion | **NEW** |
| `ac_meet_open_midcapture` | humanQuestion | **NEW** |
| `ac_mega_setup` | instruction | **NEW** — 7-step sequence |
| `ac_mega_voice` | humanQuestion | **NEW** — voice continuity across all modes |
| `ac_mega_timing` | humanQuestion | **NEW** — system audio aligned to "starting music now" |
| `ac_crash_safety_setup` | instruction | names the **ManualTestApp** process to kill |
| `ac_crash_safety_check` | humanQuestion | unchanged |
| `ac_monitoring` | humanQuestion | reworded → Google Meet instant meeting |

(Final wording: functional spec §4.3.)

### 5.3 `WiredScripts.swift`

- `wireTranscription`: keep only `tx_clear_cache` → `transcriber.clearCache()` and `tx_model_download` → `transcriber.ensureModelsDownloaded(status:)`. `tx_model_disk` + `tx_ai_test_passed` are humanQuestions (no wiring). **Remove**: `currentCapturePaths`, `latestTranscriptResult`, all transcribe/crash/autoCheck wiring, clip resolution.
- `wireAudioCapture`: unchanged (keeps the live `captureDirectory`). New `ac_*` steps are instruction/humanQuestion (no wiring).
- The hosted `transcriber` instance stays (used by the two download steps).

### 5.4 `project.yml` & resources

- No dependency change. Remove the 3 `.aac` from `Resources/` (now in test fixtures); `Info.plist` stays. `sources` unchanged.

### 5.5 Results file & staleness

- Regenerate `ManualTestApp/Results/manual_test_results.json` so every current step ID (all `ac_*` + the reduced `tx_*`) is present with `"status": "not-run"`. Stale `tx_*` keys for cut steps are simply removed/left out.
- `make manual-tests-check` stays RED until a human re-runs on hardware (expected Phase-4.5). Gating tiers unaffected.

---

## 6. Error handling & logging

- Diarization runs under SDK defaults (no override).
- AI tests surface real errors via `#expect`/throw with `detail`.
- Manual download checks keep the existing `CheckOutcome`/error pattern.
- CLI diagnostics → stderr.

---

## 7. Risks & fallbacks

1. **Diarization under defaults may not reproduce exactly 3 speakers.** Mitigated by the re-recorded clip (longer, more distinct turns). If it regresses, revisit `numberOfSpeakers` (deferred) as the more direct lever.
2. **Word-match too strict (10/10).** If a term stays stubborn even with vocab, relax `VocabGroundTruth` to a documented `N/10` naming the term — not silently.
3. **Coverage dropped:** the XPC crash-isolation manual test (`tx_crash_*`) is removed and **not** replaced by `make test-ai` (which is in-process). Accepted per scope decision (it would re-couple transcription to a live capture); easy to restore later if desired.

---

## 8. Testing strategy summary

| Layer | Tests | Tier |
|---|---|---|
| Utilities + evaluators (test-target `internal`) | fast unit tests, synthetic data | gating (`make test`) |
| Real pipeline: 3-speaker chunking + accuracy | AI test, env-gated | `make test-ai` |
| Real pipeline: custom-vocab word match | AI test, env-gated | `make test-ai` |
| Manual hardware (capture scenarios, model download UX, AI-test tracker) | ManualTestApp scripts | human (Phase 4.5) |

Coverage goal: every new pure utility + evaluator is exercised by gating unit tests; the gated AI tests validate only that real model output meets the ground truth.
