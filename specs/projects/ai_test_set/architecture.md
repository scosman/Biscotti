---
status: complete
---

# Architecture: A.5 — AI Test Set & Manual Test App Updates

Single-file architecture (medium project). No `components/` docs.

> **Scope note (revised):** the Manual Test App's *transcription* checks (quality **and** XPC crash-isolation) are **cut** — quality is covered better by the `make test-ai` AI test, and keeping the crash test would re-couple transcription to a live capture (unwanted). Consequence: the comparison utilities + ground truth live **only in the test target** (no public API on `Transcription`, no shared module), the reference clips live **only in the test fixtures** (no dupe), and the threshold knob does **not** need the XPC path. The manual transcription tab keeps only the model-download steps + a "did `make test-ai` pass?" tracker.

## 0. Change map

| Area | Change |
|---|---|
| `Packages/Transcription` — library | Add optional `diarizationClusterThreshold: Float?`, plumbed public API → engine protocol → in-process engine (+ XPC request for protocol completeness). Default `nil` = production unchanged. **No other public API changes.** |
| `Packages/Transcription` — CLI | Add `--diarization-threshold <Float>` and `--diarization-sweep <csv>` diagnostic. |
| `Packages/Transcription/Tests` | **All new test code lives here.** Comparison utilities + ground truth + evaluators (`internal` to the test target), the 3 `.aac` clips in `Fixtures/`, the env-gated `.aiModel` AI tests, and fast unit tests for the utilities + CLI + request round-trip. |
| `Packages/BiscottiKit` — `ManualTestKit` | `AudioCaptureScript.swift`: reword + add steps. `TranscriptionScript.swift`: **reduce** to download steps + a `make test-ai` tracker (cut quality **and** crash steps). |
| `ManualTestApp` | `WiredScripts.swift`: drop all transcription wiring except model download/cache; remove clip resolution + result holders. Remove the 3 `.aac` from `Resources/`. |
| `Makefile` | New `test-ai` target (env-gated, non-gating, no CI). |
| `CLAUDE.md` | Document `make test-ai`. |
| `ManualTestApp/Results/manual_test_results.json` | Regenerate with every current step ID = `not-run`. |
| Audio assets | **Move** `mic.aac`, `system.aac`, `custom_vocab_test.aac` from `ManualTestApp/Resources/` → `Tests/TranscriptionTests/Fixtures/` (single home; no dupe). |

Production targets (`App/`, `Biscotti`) are untouched and link no new code beyond the (defaulted) threshold parameter.

---

## 1. Diarization threshold plumbing

### 1.1 Public API (`Transcriber`)

```swift
public func processAudio(
    mic: URL,
    system: URL,
    customVocabulary: [String] = [],
    diarizationClusterThreshold: Float? = nil   // NEW; nil ⇒ SDK default
) async throws -> TranscriptResult
```

`reTranscribe(...)` unchanged. A defaulted trailing parameter is source-compatible.

### 1.2 Engine seam (`TranscriptionEngine`)

```swift
func processAudio(
    micPath: String, systemPath: String,
    customVocabulary: [String],
    diarizationClusterThreshold: Float?          // NEW
) async throws -> TranscriptResult
```

All conformers update: `InProcessTranscriptionEngine`, the XPC adapter, the test stub. Compiler-enforced.

### 1.3 In-process engine (the only consumer that uses the value)

```swift
func runDiarization(audioArray: [Float], clusterThreshold: Float?) async throws -> DiarizationResult {
    let options = clusterThreshold.map { PyannoteDiarizationOptions(clusterDistanceThreshold: $0) }
    return try await speaker.diarize(audioArray: audioArray, options: options)
}
```

- `clusterThreshold == nil` ⇒ `options == nil` ⇒ `diarize(audioArray:)` called exactly as today (byte-for-byte production behavior). `numberOfSpeakers` not set (deferred).

### 1.4 XPC path (completeness only)

The XPC adapter must satisfy the protocol, so `XPCProcessRequest` gains `let diarizationClusterThreshold: Float?` (Codable; transparent over the JSON `@objc` boundary) and the service forwards it. **No current consumer exercises this** (the ManualTestApp no longer transcribes; the AI test + CLI use `.inProcess`). Kept for an honest, complete protocol implementation and covered by a round-trip unit test.

### 1.5 CLI diagnostics (`transcribe-cli`)

```
--diarization-threshold <Float>     Override cluster-distance threshold (default: SDK default).
--diarization-sweep <csv>           Diagnostic: per threshold, run the pipeline and print
                                    "<threshold>: speakers=<count> distinct=<n>". Skips normal output.
```

- `--diarization-threshold` forwards to `processAudio(diarizationClusterThreshold:)`.
- `--diarization-sweep "0.30,0.35,0.40,0.45,0.50"`: calls `processAudio` per threshold (models stay warm in-process) and prints, to **stderr**, the SDK `speakerCount` and the distinct-speaker count computed inline from `result.segments` (`Set(segments.compactMap{$0.speakerID}).count`) — **no dependency on the test-target chunker**. One human run reveals the value yielding 3 speakers. The chosen value is written into the test's `GroundTruth.tunedDiarizationClusterThreshold`.
- Diagnostics → stderr (keeps stdout clean per research gotcha #15).

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
        .init(speakerLabel: "A", script: "Hello, this is a test of the system."),
        .init(speakerLabel: "B", script: "Hello, I am person number two. I am saying something back."),
        .init(speakerLabel: "C", script: "Hi, I'm person number three and you two are banana heads."),
    ]
    static let chunkLevenshteinTolerance = 0.05
    static let vocabTerms = ["NASA","Kubernetes","Postgres","Qwen","Mistral","Llama",
                             "Croissant","gnocci","Paella","Facade"]
    static let tunedDiarizationClusterThreshold: Float = 0.40   // PLACEHOLDER — finalize from §1.5 sweep
}

struct ChunkEvaluation { let chunkCount, distinctSpeakers: Int; let perChunkRatios: [Double]
                         let passed: Bool; let detail: String }   // passed = count==3 && distinct==3 && all ratio<=tol
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
let r = try await Transcriber(backend: .inProcess).processAudio(
    mic: mic, system: sys, diarizationClusterThreshold: GroundTruth.tunedDiarizationClusterThreshold)
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
- chunk count ≠ 3 ⇒ `detail` reports observed count + per-chunk speaker IDs; ratios omitted.
- `speakerID == nil` segments form their own chunk ⇒ count/distinctness fails loudly.

### 3.5 Fast (non-AI) unit tests — gating tier

In the same target, no gate, no models:
- `Levenshtein`, `TextNormalize`, `TranscriptChunker` (same-speaker merge, A/B/A → 3 chunks/2 distinct, nil speaker), `WordMatch` (all/none/partial, punctuation, case).
- `DiarizationGroundTruth.evaluate` / `VocabGroundTruth.evaluate` on synthetic `TranscriptResult`s (pass + each failure mode).
- CLI parse (`--diarization-threshold`, `--diarization-sweep` csv→[Float]).
- `XPCProcessRequest` Codable round-trip with/without `diarizationClusterThreshold`.

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

- Threshold: `nil` is the only production value; non-nil only from tests/CLI. Out-of-range values pass straight to the SDK; no extra clamping.
- AI tests surface real errors via `#expect`/throw with `detail`.
- Manual download checks keep the existing `CheckOutcome`/error pattern.
- CLI diagnostics → stderr.

---

## 7. Risks & fallbacks

1. **Tuned threshold may not yield a clean 3.** Mitigated by the sweep (pick `speakers=3 distinct=3`). If no single threshold works on this clip, surface for a decision (e.g. `numberOfSpeakers` hint) rather than hardcoding silently — the test asserts the end state.
2. **Word-match too strict (10/10).** If a term stays stubborn even with vocab, relax `VocabGroundTruth` to a documented `N/10` naming the term — not silently.
3. **Protocol param ripple.** `diarizationClusterThreshold` touches every `TranscriptionEngine` conformer + the XPC request; all in-package, compiler-enforced.
4. **Coverage dropped:** the XPC crash-isolation manual test (`tx_crash_*`) is removed and **not** replaced by `make test-ai` (which is in-process). Accepted per scope decision (it would re-couple transcription to a live capture); easy to restore later if desired.

---

## 8. Testing strategy summary

| Layer | Tests | Tier |
|---|---|---|
| Utilities + evaluators (test-target `internal`) | fast unit tests, synthetic data | gating (`make test`) |
| CLI flags + `XPCProcessRequest` round-trip | unit tests | gating |
| Real pipeline: 3-speaker chunking + accuracy | AI test, env-gated | `make test-ai` |
| Real pipeline: custom-vocab word match | AI test, env-gated | `make test-ai` |
| Manual hardware (capture scenarios, model download UX, AI-test tracker) | ManualTestApp scripts | human (Phase 4.5) |

Coverage goal: every new pure utility + evaluator is exercised by gating unit tests; the gated AI tests validate only that real model output meets the ground truth.
