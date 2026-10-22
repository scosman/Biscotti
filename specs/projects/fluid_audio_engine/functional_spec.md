---
status: draft
---

# Functional Spec: FluidAudio Engine

## 1. Goal

Add a second transcription engine to `Packages/Transcription` — **FluidAudio**
(NVIDIA Parakeet TDT 0.6B v3 for STT + FluidAudio's offline VBx pyannote
community-1 pipeline for diarization) — and make it the default. The existing
WhisperKit + SpeakerKit engine stays in the package as a selectable
alternative.

Nothing above `Packages/Transcription` changes behaviour. `Transcribing`,
`TranscriptResult`, `TranscriptSegment`, `TranscriptWord` and the
`BiscottiTranscriber` XPC topology are all preserved.

### Why

- **Speed.** Parakeet TDT v3 runs at ~110–190x real time on Apple Silicon vs
  Whisper large-v3's much slower decode. A one-hour meeting should transcribe
  in tens of seconds.
- **Optionality.** A second engine behind the existing opaque
  `TranscriptionMethod` id lets us A/B quality on real meetings and roll back
  by changing one constant.
- **Unblocking.** FluidAudio's offline diarizer exposes per-speaker embeddings,
  which `specs/architecture.md` currently records as unavailable (SpeakerKit
  v1.0.0 does not expose centroids). This project does not build the voiceprint
  feature, but it removes the blocker.

### Decisions taken (confirmed with the user)

| Decision | Choice |
|---|---|
| Diarizer | `OfflineDiarizerManager` — pyannote community-1 segmentation + WeSpeaker embeddings + PLDA/VBx clustering. No speaker cap, batch-oriented, exposes embeddings. |
| Engine strategy | **Dual engine from the start.** `MethodResolver` dispatches on engine in phase one; both SDKs ship. |
| Custom vocabulary | **Out of scope.** `customVocabulary` stays accepted-but-unapplied on the FluidAudio path, with a `TODO` pointing at FluidAudio's CTC boosting. |

---

## 2. What the two engines are

### `TranscriptionMethod.v1` — WhisperKit (existing, unchanged)

- STT: `openai_whisper-large-v3-v20240930_626MB` from `argmaxinc/whisperkit-coreml`
- Diarization: SpeakerKit / Pyannote v4 community-1, `.subsegment` strategy
- Word↔speaker alignment: done by the SDK (`DiarizationResult.addSpeakerInfo`)
- Custom vocabulary: attempted via `promptTokens` (known-broken upstream —
  argmax-oss-swift#489); behaviour is preserved exactly as it is today
- Sequential model loading on ≤ 8 GB machines

**v1 output must be byte-identical to today's output for the same input.** It is
the rollback path and the control arm of the comparison.

### `TranscriptionMethod.v2` — FluidAudio (new, becomes `.current`)

- STT: `AsrManager` with `AsrModels` version `.v3`
  (`FluidInference/parakeet-tdt-0.6b-v3-coreml`), int8 encoder, batch path
- Diarization: `OfflineDiarizerManager` with `OfflineDiarizerConfig.default`
  (`FluidInference/speaker-diarization-coreml`)
- Word↔speaker alignment: **ours** (see §4) — FluidAudio has no equivalent of
  `addSpeakerInfo`
- Custom vocabulary: ignored (documented `TODO`)
- No sequential-loading special case: the two model sets together are far
  smaller than Whisper large-v3, so both stay resident for the run

`TranscriptionMethod.current` becomes `.v2`.

---

## 3. What FluidAudio gives us, and what it does not

This is the crux of the project. The two SDKs are **not** shaped the same way.

| Need | WhisperKit + SpeakerKit | FluidAudio | Consequence |
|---|---|---|---|
| Transcript text | Segmented, per-segment | One `String` for the whole clip | We segment it ourselves |
| Word timings | `WordTiming` with `probability` | `[TokenTiming]` (sub-word) with `confidence` | We group tokens → words ourselves |
| Speaker per word | SDK does it (`addSpeakerInfo`) | Nothing — diarizer runs independently | **We write the aligner** |
| Speaker id type | `Int` | `String` (`"S1"`, `"S2"`, …) | We map to stable `Int`s |
| Segment confidence | `avgLogprob` (unreliable, often 0) | Not provided | Derive from word probabilities |
| `noSpeechProbability` | Provided | Not provided | Fixed at `0` |
| Detected language | Provided | **Not provided** (the `language:` argument is a *decode hint*, not detection) | Detect from text with `NLLanguageRecognizer` |
| Speaker embeddings | Not exposed | `speakerDatabase: [String: [Float]]` + per-chunk embeddings | Available; not consumed by this project |
| Download progress | File-count weighted (deliberately not shown as a %) | `DownloadProgress.fractionCompleted` | Real % is available; not adopted here (see §9) |
| Audio loading | `AudioProcessor.loadAudioAsFloatArray` | `AudioConverter.resampleAudioFile(_:)` | Each engine keeps its own loader |

### Open questions that must be answered on hardware, not from docs

1. **Does Parakeet TDT v3 emit punctuation and capitalization?** NVIDIA's model
   card says yes; FluidAudio's own `Documentation/Benchmarks.md` describes TDT
   v3 as "multilingual, no punctuation" and says the English-only
   `parakeet-unified-en-0.6b` build "wins on WER, throughput, and punctuation".
   Meanwhile `Documentation/ASR/LongTranscription.md` discusses mid-word
   punctuation artefacts *in v3 output*, which implies it does punctuate. This
   is unresolved in the documentation and is the single biggest quality risk of
   the swap — an unpunctuated, uncapitalised transcript would be a serious
   regression for reading and would degrade LLM summarisation.
2. **What is the numeric range of `TokenTiming.confidence`?** `TranscriptSanitizer`
   drops a trailing single-word segment when its word probability is `< 0.3`,
   which assumes a `0…1` probability. If Parakeet reports a log-probability the
   rule silently misfires.
3. **Do FluidAudio's public signatures match its README?** The README quick
   start shows `asrManager.transcribe(samples)`, but the source requires
   `transcribe(_:decoderState:language:)` with an `inout TdtDecoderState`. The
   docs lag the source.

**Both (1) and (2) are resolved by a spike in the first implementation phase,
before any production code is written.** (3) is handled by pinning an exact
version and reading signatures from source.

### Fallback if Parakeet v3 does not punctuate

Documented, not built: swap the v2 STT model to
`FluidInference/parakeet-unified-en-0.6b-coreml` via `UnifiedAsrManager`
(English-only, punctuation + capitalisation, 2.15% avg WER, 123x RTFx,
`transcribeWithTimings` returns the same `[TokenTiming]` shape). Because the
engine is selected by method id and the token-timing contract is identical,
this is a change to one resolver branch — which is precisely why the spike runs
first.

---

## 4. New behaviour we own: transcript assembly

FluidAudio returns a flat transcript and an independent speaker timeline. Three
new pure functions turn that into `[TranscriptSegment]`. All three are
deterministic, dependency-free, and unit-tested without models.

### 4.1 Token → word grouping

Input `[TokenTiming]`, output `[TranscriptWord]`.

- A token begins a new word when its raw piece starts with the SentencePiece
  word-boundary marker (`▁`) or a leading space; otherwise it appends to the
  current word.
- Blank/pad tokens (`""`, `<blank>`, `<pad>`) are skipped.
- The word spans the first sub-word token's `startTime` to the last's `endTime`.
- `TranscriptWord.probability` is the **mean of the constituent tokens'
  `confidence`**.

FluidAudio ships `buildWordTimings(from:)` with the same grouping rule but it
discards confidence, so we implement our own rather than losing the only
quality signal `TranscriptSanitizer` has.

### 4.2 Word → speaker assignment

Input `[TranscriptWord]` + `[TimedSpeakerSegment]`, output words with
`speakerID` set.

- A word is assigned to the speaker segment with the **largest temporal
  overlap** with `[word.startTime, word.endTime)`.
- If no segment overlaps, the word is assigned to the nearest segment whose
  boundary is within **0.5 s**; ties break toward the earlier segment.
- If still nothing, `speakerID` is `nil`.
- Words are never split across speakers.

### 4.3 Word → segment assembly

Input speaker-assigned `[TranscriptWord]`, output `[TranscriptSegment]`.

- Consecutive words with the same `speakerID` form one segment.
- A segment is also cut when the silent gap between two adjacent words exceeds
  **2.0 s**, so a long pause does not produce one enormous segment.
- Per segment:
  - `startTime` / `endTime` — first word's start, last word's end
  - `text` — words joined with a single space, then trimmed
  - `confidence` — mean of the segment's word probabilities (0 if no words)
  - `noSpeechProbability` — `0` (not available; documented)
  - `words` — the segment's words, never `nil` on this path
- Segments are ordered by `startTime`.

### 4.4 Speaker id mapping

FluidAudio speaker ids are opaque strings. They are mapped to `Int` by **order
of first appearance in the assembled segment list**: first speaker seen → `0`,
next new speaker → `1`, and so on. `speakerLabel` is `"Speaker <n>"`, matching
what v1 produces. Unassigned words produce `speakerID: nil` and
`speakerLabel: "Unknown"`.

This must be deterministic: the same audio must yield the same ids on every
run, because the transcript is persisted and the Intelligence module maps
speaker ids to human names.

`TranscriptResult.speakerCount` is the number of distinct assigned speakers.

### 4.5 Language

`language` is set by running `NLLanguageRecognizer` (Apple's `NaturalLanguage`
framework — on-device, no new dependency) over the assembled transcript text,
taking the dominant language's ISO code. Falls back to `"unknown"` when the
text is empty or no language clears the recogniser's confidence.

The field is persisted but drives no behaviour anywhere in the app today, so a
mis-detection is cosmetic.

### 4.6 Sanitising

`TranscriptSanitizer` continues to run on both engines' output, unchanged:
drop segments starting at or past the audio duration, clamp overhanging end
times, drop low-confidence trailing single-word segments. Its trailing-word
threshold is validated against Parakeet's confidence range in the spike; if the
range differs the threshold becomes a per-engine resolved setting rather than a
constant.

### 4.7 Speaker embeddings

`TranscriptResult.speakerEmbeddings` **stays empty** on both engines. FluidAudio
can populate it from `DiarizationResult.speakerDatabase`, but `DataStore` does
not persist the field, so filling it would only add payload to every XPC
round-trip for no consumer. A `TODO` records that the data is now available for
whoever builds cross-meeting voiceprints.

---

## 5. Public API of the Transcription package

### Unchanged

`Transcriber` (actor), `TranscriptionEngine` (protocol), `TranscriptResult`,
`TranscriptSegment`, `TranscriptWord`, `ModelStatus`, `TranscriptionError`,
`TranscriptSanitizer`, `Transcriber.Backend`.

### Changed

**`TranscriptionMethod`**

```
.v1       // WhisperKit large-v3 + SpeakerKit pyannote (existing)
.v2       // FluidAudio Parakeet TDT v3 + offline VBx pyannote community-1
.current  // == .v2
```

The id stays an opaque `String` and unknown ids continue to fall back to a
working method — but the fallback target becomes `.v2`, since that is what
`.current` means going forward. Existing persisted transcripts keep
`transcriptionMethodId: "v1"`; nothing rewrites them.

**`MethodResolver`** resolves a method to an engine *kind* plus that engine's
settings, instead of one flat settings struct. Callers outside the package are
unaffected — the type is internal.

**`Transcriber.modelsPresent()`** answers for the method the `Transcriber` was
constructed with. Today it hard-codes WhisperKit + SpeakerKit disk probes.

**`transcribe-cli`** gains a `--method <id>` option (default `.current`) so both
engines can be exercised from the command line without rebuilding, and prints
the method id it actually used.

### XPC protocol

The worker currently resolves the method internally from
`TranscriptionMethod.current`. With two engines the method must cross the
boundary:

- `XPCProcessRequest` gains `methodId: String`.
- `TranscriberServiceProtocol.ensureModelsDownloaded` gains a `methodId`
  parameter.

This is an internal protocol between the app and its own bundled XPC service —
both ship in the same app bundle and version together, so there is no
compatibility window to manage.

---

## 6. Model storage, download and lifecycle

### Location

FluidAudio defaults to `~/Library/Application Support/FluidAudio/Models/`. That
is the wrong place for us — Biscotti owns one model cache so that "clear cache"
and disk accounting stay honest. Both FluidAudio download entry points accept a
directory (`AsrModels.download(to:)`,
`OfflineDiarizerManager.prepareModels(directory:)`), so models land under the
existing root:

```
~/Library/Application Support/Biscotti/models/
├── argmaxinc/whisperkit-coreml/…        # v1 STT       (unchanged)
├── argmaxinc/speakerkit-coreml/…        # v1 diarizer  (unchanged)
└── fluidaudio/
    ├── parakeet-tdt-0.6b-v3/…           # v2 STT
    └── speaker-diarization/…            # v2 diarizer
```

`ModelStorage.clearCache()` already removes `models/` wholesale, so it covers
both engines with no change.

### Download

`ensureModelsDownloaded(status:)` keeps its contract: a disk-space check, then
human-readable stage messages through the existing callback. On the FluidAudio
path the stages are `"Downloading speech-to-text model"` and
`"Downloading speaker ID model"` — the same strings v1 emits, so no UI copy
changes and the onboarding/settings download screens are untouched.

The disk-space pre-check uses a per-engine estimate. The FluidAudio figure is
measured during the spike rather than guessed; the check must not be so tight
that a legitimate download is refused, nor so loose that it fills the disk.

`ModelHub.offlineMode` is **not** enabled — the app must be able to download on
first run. Network failures surface as `TranscriptionError.downloadFailed` as
they do today.

### Presence probe

`modelsPresent()` stays a read-only filesystem check that never downloads,
loads, or compiles. For v2 it uses
`AsrModels.modelsExist(at:version:encoderPrecision:)` plus a `.mlmodelc` probe
of the diarizer directory, mirroring the existing WhisperKit/SpeakerKit probes.

### Unload

`unloadModels()` releases both FluidAudio managers (`AsrManager.cleanup()` and
dropping the `OfflineDiarizerManager`). The XPC host still exits when its last
connection closes, so worker memory is reclaimed either way.

---

## 7. Errors

FluidAudio's error types map onto the existing `TranscriptionError` cases. No
new cases are added, so no call site above the package changes.

| FluidAudio | `TranscriptionError` |
|---|---|
| `ASRError.notInitialized`, `.modelLoadFailed`, `.modelCompilationFailed`, `.encoderInstantiationFailed` | `.modelLoadFailed` |
| `ASRError.invalidAudioData`, `.fileAccessFailed`, `.streamingConversionFailed` | `.invalidInput` |
| `ASRError.processingFailed`, `.unsupportedPlatform` | `.transcriptionFailed` |
| `DiarizerError.*` | `.diarizationFailed` (`.notInitialized` / compilation → `.modelLoadFailed`) |
| `AsrModelsError.downloadFailed`, `DownloadError.*` | `.downloadFailed` |
| `AsrModelsError.loadingFailed`, `.modelNotFound`, `.modelCompilationFailed` | `.modelLoadFailed` |

Unrecognised errors fall through to `.transcriptionFailed(description)`, as
today. A worker crash still surfaces as `.workerInterrupted` via the existing
`NSXPCConnection` interruption handling — unchanged.

### Edge cases

| Case | Behaviour |
|---|---|
| Audio shorter than Parakeet's 300 ms minimum | `ASRError.invalidAudioData` → `.invalidInput`, with the file path in the message |
| Transcript produced but diarizer finds no speakers | Segments are still produced; every word has `speakerID: nil`, `speakerLabel: "Unknown"`, `speakerCount: 0` |
| Diarizer finds speakers but ASR returns empty text | Empty `segments`, `speakerCount: 0`, no throw — matches how v1 handles a silent recording |
| Diarizer segments extend past the last word | Ignored; only words drive segment assembly |
| Unknown `methodId` over XPC | Falls back to `.current` (`.v2`) and logs, rather than throwing |
| Mixed-language meeting | One dominant language recorded; the transcript itself is unaffected (v3 is multilingual) |

---

## 8. Testing

### Unit tests — run in `make test`, no models, no network

The assembly logic in §4 is pure and is tested directly: token→word grouping
(including boundary markers, blanks, single-token words, empty input),
overlap-based speaker assignment (exact overlap, partial, no overlap inside and
outside the 0.5 s tolerance, ties), segment assembly (speaker change, silence
split, confidence averaging), speaker-id determinism, language detection
fallback, method→engine resolution, and the error mapping table.

### AI tests — `make test-ai`, human-run, non-gating

`AIModelTests` already carries ground truth for the 3-speaker fixture
(`mic_fixture.wav` / `system_fixture.wav`): five chunks, three distinct
speakers, per-chunk Levenshtein ≤ 0.05. This is the **acceptance gate for the
swap**.

- The existing test is parameterised over method, so v1 and v2 both run against
  the same ground truth.
- v2 must meet the same bar as v1 on speaker structure and transcript accuracy.
- A new assertion records processing duration for both engines, so the speed
  claim is measured rather than assumed.

Ground truth is normalised for case and punctuation before the Levenshtein
comparison, so the test is not itself the arbiter of the punctuation question —
that is answered by eye in the spike.

### Manual tests

Per the repo's staleness rule, touching `Packages/Transcription` marks every
`tx_*` step `not-run` in `ManualTestApp/Results/manual_test_results.json`. The
existing steps (`tx_model_download`, `tx_model_disk`, `tx_clear_cache`,
`tx_ai_test_passed`) all still apply and must be re-run on hardware. The
transcription tab gains an engine picker so a human can run the same script
against both engines and compare output side by side.

`make manual-tests-check` will be RED from the first commit until that hardware
pass happens. It is non-gating, as designed.

---

## 9. Explicitly out of scope

- **Custom vocabulary.** FluidAudio's CTC boosting does work with Parakeet 0.6B
  and would unblock what `CLAUDE.md` records as blocked, but it needs a second
  97.5 MB model and glue that FluidAudio only wires into its *streaming*
  manager. Deferred; a `TODO` on the FluidAudio path records it.
- **Numeric download progress.** `DownloadProgress.fractionCompleted` is a real
  fraction, unlike WhisperKit's file-count weighting. Adopting it means
  changing the `TranscriberStatusReporting` XPC protocol and the UI copy.
  Deferred; `TODO`.
- **Populating `speakerEmbeddings`** (§4.7).
- **Streaming / live transcription.** FluidAudio has strong streaming support;
  Biscotti transcribes after the recording stops. Unchanged.
- **Any change above `Packages/Transcription`** other than the XPC service's own
  `methodId` plumbing. No UI, no `DataStore` schema, no `AppCore` changes.
- **Removing WhisperKit.** Both engines ship.
- **VAD, TTS, speaker enrolment, ITN** — other FluidAudio capabilities, not
  needed here.

---

## 10. Constraints and risks

| Risk | Severity | Handling |
|---|---|---|
| Parakeet v3 may not punctuate or capitalise | **High** | Resolved by the phase-1 spike before production code; documented fallback to `parakeet-unified-en-0.6b` (§3) |
| We now own word↔speaker alignment that the SDK used to do | **High** | Pure, unit-tested logic (§4); the 3-speaker AI test is the end-to-end gate |
| FluidAudio pulls a **binary xcframework** (`NemoTextProcessing`) plus two C targets (`FastClusterWrapper`, `MachTaskSelfWrapper`) and needs `cxxLanguageStandard: .cxx17` — new signing/notarization surface inside an XPC service | Medium | Prove `make build-app` and an ad-hoc-signed launch early; carry the finding into Project 9 (signing/notarization) |
| App size grows: both SDKs plus two model sets on disk | Medium | Accepted — dual engine was chosen deliberately. Both model sets live under one cache root that "clear cache" empties |
| FluidAudio docs lag its source (README quick start does not compile) | Medium | Pin an exact version, not a range; read signatures from source; the spike compiles against the pinned version |
| FluidAudio moves fast (0.x, frequent releases) | Medium | Exact pin; upgrades become deliberate, reviewed changes |
| Confidence semantics differ, silently breaking the sanitizer's trailing-word rule | Low | Range verified in the spike; threshold becomes a per-engine setting if needed |
| v1 behaviour regressing during the refactor | Low | v1 output must stay byte-identical; existing v1 tests are the guard |

### Platform

FluidAudio requires macOS 14 / iOS 17; Biscotti targets macOS 15 on Apple
Silicon, so there is headroom. `AsrModels` requires Apple Silicon, which the
project already mandates. The int8 encoder issue FluidAudio reports on A16
(iOS) does not apply to M-series Macs.

### Performance target

A one-hour recording should transcribe substantially faster than today.
Measured, not assumed: the AI test records processing duration for both
engines on the same fixture.
