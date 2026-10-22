# How SpeakerKit couples to WhisperKit

Source read: `argmax-oss-swift` cloned Oct 21 2026; tags `v1.0.0` (`25c6299`, 2026-05-01, **what Biscotti pins**), `v1.1.0` (2026-08-06), `v1.1.1` (2026-10-07, latest). Links point at v1.1.1 unless stated. Where v1.0.0 differs, that is called out.

## 1. Package-level coupling: SpeakerKit depends on the WhisperKit target

[`Package.swift`](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.1/Package.swift):

```swift
.target(
    name: "SpeakerKit",
    dependencies: [
        "ArgmaxCore",
        "WhisperKit",
    ],
```

Consequence: **we cannot drop the WhisperKit module while keeping SpeakerKit.** Removing `.product(name: "WhisperKit", …)` from `Packages/Transcription/Package.swift` only removes our direct import; SwiftPM still builds and links the WhisperKit module into the XPC service because SpeakerKit needs it. What we *can* drop is WhisperKit **models** (the ~626 MB Whisper download) and all WhisperKit **runtime use** — the module costs binary size only. (I did not measure the binary-size cost.)

## 2. What SpeakerKit uses from WhisperKit

`grep` of `Sources/SpeakerKit` for WhisperKit symbols (v1.1.1):

| WhisperKit symbol | Where | Kind of coupling |
|---|---|---|
| `TranscriptionResult` (input to `addSpeakerInfo`, `generateRTTM`) | `DiarizationResult.swift` L182, `SpeakerKit.swift` L83 | **Type** — the alignment API's input |
| `TranscriptionSegment` (`SpeakerSegment.transcription`, sub-segment synthesis) | `SpeakerSegment.swift` L30, `DiarizationResult.swift` | **Type** |
| `WordTiming` (`SpeakerWordTiming.wordTiming`, `RTTMLine`) | `SpeakerInfo.swift` L75, `RTTMLine.swift` L9 | **Type** |
| `WhisperKit.sampleRate` (16000) | `PyannoteDiarizer.swift` L119/159/178 | Constant |
| `AudioProcessor.padOrTrimAudio` | `SpeakerSegmenterModel.swift` L178 | Utility function |

No WhisperKit **model**, tokenizer or decoder is touched by diarization. `SpeakerKit.init(_:)` only builds a Pyannote diarizer and downloads from `argmaxinc/speakerkit-coreml` ([`SpeakerKit.swift`](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.1/Sources/SpeakerKit/SpeakerKit.swift) L21-37).

## 3. Diarization runs standalone on raw audio

```swift
open func diarize(
    audioArray: [Float],                       // "16 kHz mono PCM samples"
    options: (any DiarizationOptions)? = nil,  // PyannoteDiarizationOptions
    progressCallback: (@Sendable (Progress) -> Void)? = nil
) async throws -> DiarizationResult
```

([`SpeakerKit.swift`](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.1/Sources/SpeakerKit/SpeakerKit.swift) L63-71.) The upstream README's first SpeakerKit example uses only `import SpeakerKit` and prints `result.segments` with no transcription ([README §SpeakerKit](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.1/README.md#speakerkit)). `generateRTTM(from:transcription: nil)` also works without any transcript.

`DiarizationResult` public surface ([`DiarizationResult.swift`](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.1/Sources/SpeakerKit/DiarizationResult.swift)):

```swift
public struct DiarizationResult: Sendable {
    public let speakerCount: Int
    public let totalFrames: Int
    public let frameRate: Float
    public private(set) var segments: [SpeakerSegment]       // the speaker timeline
    public var timings: (any DiarizationTimings)?
    public private(set) var speakerCentroidEmbeddings: [Int: [Float]]   // v1.1.0+ only
    public mutating func updateSegments(minActiveOffset: Float)
    public func centroidCosineDistance(between a: Int, and b: Int) -> Float?        // v1.1.0+
    public func nearestSpeakerCentroid(to embedding: [Float]) -> (speakerId: Int, distance: Float)?  // v1.1.0+
    public func addSpeakerInfo(to transcription: [TranscriptionResult], strategy: SpeakerInfoStrategy = .subsegment) -> [[SpeakerSegment]]
}
```

Each timeline `SpeakerSegment` has public `speaker: SpeakerInfo` (`.speakerId(Int)` / `.noMatch` / `.multiple`), `startTime`/`endTime: Float` seconds, `startFrame`/`endFrame`. So **a speaker timeline is available independent of any STT**.

### Timeline resolution

`frameRate` is read from the segmenter model's output shape at runtime (`SpeakerSegmenterModel.modelSampleRate` = frames-per-window ÷ window seconds). The shipped segmenter's metadata ([`speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc/metadata.json`](https://huggingface.co/argmaxinc/speakerkit-coreml/tree/main/speaker_segmenter/pyannote-v3/W8A16)) declares `speaker_ids [21, 589, 3]` and `sliding_window_waveform [21, 1, 160000]` → 589 frames per 10 s window = **~58.9 frames/s (~17 ms per frame)**. Default `useExclusiveReconciliation: true` assigns at most one speaker per frame (no overlap labels), so `.multiple` is not produced on the default path.

## 4. The alignment step (`addSpeakerInfo`) — exactly what it does

`addSpeakerInfo(to: [TranscriptionResult], strategy:)` maps each `TranscriptionResult` to `[SpeakerSegment]`:

- **`.segment`**: each `TranscriptionSegment` is matched to the diarization segment with the highest **IoU** of frame ranges.
- **`.subsegment(betweenWordThreshold: 0.15)`** (default and Biscotti v1): within each segment, words are split into sub-segments wherever `curr.start - prev.end > 0.15` s; each sub-segment is matched to the diarization segment with the largest **raw frame intersection**; the sub-segment's text is `words.map(\.word).joined(separator: "")`, and SpeakerKit fabricates a `TranscriptionSegment` for it with `avgLogprob: 0.0`, `noSpeechProb: 0.0`, `tokens: []`.
- **Both strategies drop any segment with `words == nil` or empty** (`validateWordsInSegment` logs "Enable `wordTimestamps` on DecodingOptions." and returns nil → `continue`). Word timings are mandatory.
- All words in a (sub)segment get the same speaker. If no diarization segment overlaps, the **previous speaker** is reused (initially `.noMatch`).
- Frame mapping: `Int(seconds * frameRate)`; matching scans diarization segments sorted by start and stops when one starts after the (sub)segment ends.

Fields of the input it actually reads: `TranscriptionResult.segments`; per segment `start`, `end`, `words` (and `id` for a log line); per word `word`, `start`, `end` (`probability` and `tokens` are carried through, not used for matching). `text`, `language`, `timings`, `tokens`, `avgLogprob`, etc. are not used for alignment.

## 5. Can another engine's output feed `addSpeakerInfo`? Yes — the input types are publicly constructible

All three WhisperKit types have public memberwise inits with defaults ([`Sources/WhisperKit/Core/Models.swift`](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.1/Sources/WhisperKit/Core/Models.swift)):

```swift
open class TranscriptionResult: Codable, @unchecked Sendable {
    public init(text: String, segments: [TranscriptionSegment], language: String,
                timings: TranscriptionTimings, seekTime: Float? = nil)
}
public struct TranscriptionSegment: Hashable, Codable, Sendable {
    public init(id: Int = 0, seek: Int = 0, start: Float = 0.0, end: Float = 0.0, text: String = "",
                tokens: [Int] = [], tokenLogProbs: [[Int: Float]] = [[:]], temperature: Float = 1.0,
                avgLogprob: Float = 0.0, compressionRatio: Float = 1.0, noSpeechProb: Float = 0.0,
                words: [WordTiming]? = nil)
}
public struct WordTiming: Hashable, Codable, Sendable {
    public init(word: String, tokens: [Int], start: Float, end: Float, probability: Float)
}
// TranscriptionTimings has `public init(modelLoading: TimeInterval = 0, …)` — every parameter defaulted.
```

So a bridge is a few lines (illustrative):

```swift
let words = engineWords.map { WordTiming(word: " " + $0.text, tokens: [], start: $0.start, end: $0.end, probability: $0.conf ?? 1) }
let seg = TranscriptionSegment(start: words.first?.start ?? 0, end: words.last?.end ?? 0, text: …, words: words)
let fake = TranscriptionResult(text: …, segments: [seg], language: "en", timings: TranscriptionTimings())
let groups = diarization.addSpeakerInfo(to: [fake], strategy: .subsegment)   // existing SegmentBuilder unchanged
```

`SegmentBuilder` and everything downstream then work unchanged. The `specs/projects/fluid_audio_engine/functional_spec.md` draft says "Speaker per word: Nothing — diarizer runs independently → **We write the aligner**". That is not required: we may write one (option B below), but `addSpeakerInfo` accepts constructed input.

### Option A — reuse `addSpeakerInfo` via constructed WhisperKit types
- Pros: behaviour parity with v1 attribution; ~30 lines of glue; `SegmentBuilder`/`TranscriptSanitizer` untouched.
- Cons: WhisperKit types become our interchange format (they are public, documented API, low churn — `Models.swift` changed by 7 lines between v1.0.0 and v1.1.1, none in these types); inherits the algorithm's limits (one speaker per sub-segment, gap-based splitting only).

### Option B — own aligner over `DiarizationResult.segments`
- `segments` exposes `speaker`, `startTime`, `endTime` publicly, so a per-word (or per-sentence) speaker assignment can be written in our package without WhisperKit types (~50–100 lines).
- Pros: can split on punctuation or per word, handle engines whose word timings have no pauses (see `alignment-requirements.md`), free of WhisperKit types in our code.
- Cons: we own correctness/tests; parity with today must be re-validated.

Both are viable; neither needs WhisperKit models.

## 6. Our deeper hooks — status and WhisperKit dependence

| Hook | Status in repo | Depends on WhisperKit? |
|---|---|---|
| `.subsegment` strategy | In use (`MethodResolver.resolveV1`) | Only through input **types** (`TranscriptionResult`/`WordTiming`), which are constructible (§5). |
| Centroid embeddings (`speakerCentroidEmbeddings`) | **Not used.** `TranscriptResult.speakerEmbeddings` is hard-coded `[:]` (`InProcessTranscriptionEngine.assembleResult`). The API does not exist at the pinned v1.0.0 (confirmed: no `speakerCentroid` symbol in v1.0.0 `DiarizationResult.swift`). It was added by [PR #463](https://github.com/argmaxinc/argmax-oss-swift/pull/463) (merged 2026-06-02, closes [#457](https://github.com/argmaxinc/argmax-oss-swift/issues/457)) and shipped in [v1.1.0](https://github.com/argmaxinc/argmax-oss-swift/releases/tag/v1.1.0): "speaker centroid embeddings are now available from a public interface, useful for matching speakers across separate diarization runs." | **No.** Computed in the Pyannote clusterer from 256-dim embedder output (`speaker_embeddings [1, 64, 256]` in the embedder [metadata](https://huggingface.co/argmaxinc/speakerkit-coreml/tree/main/speaker_embedder/pyannote-v3/W8A16)). Raw space, "unnormalised, pre-PLDA"; options `centroidSource: .finalAssignment` (default) / `.trainableOnly`. No same-speaker threshold is defined upstream ("callers should calibrate"). |
| PLDA-space centroids | Proposed in [PR #540](https://github.com/argmaxinc/argmax-oss-swift/pull/540) — **closed without merge** (merged_at null). | n/a |
| Voice-prints / "embed this clip" API | Not available. Issue #457 asked for `embed(audioArray:)`; only centroids shipped. `SpeakerEmbedderModel` is a public class but its `embed` is internal. Enrollment would mean diarizing a clip and taking its centroid. | No |
| Voice-print store / `Person` voiceprints | Reserved only: `DataStore/Models/Person.swift` "Reserved for P2: voiceprint/centroid embeddings"; `specs/architecture.md` L392 and `specs/implementation_plan.md` L134-139 (P2). | n/a |
| Mic-vs-system "me" heuristic | Planned (P2), not built. Uses diarization timeline + `AudioMerger` labels. | No |

So **none of the deeper hooks depends on WhisperKit**; the only WhisperKit-shaped thing is the input type of `addSpeakerInfo`. Note the "deeper hooks" are mostly *planned*, not built: in shipping code the app uses only SpeakerKit's speaker IDs/labels/count via `.subsegment` alignment. To use centroids at all, the repo must bump `argmax-oss-swift` from the pinned 1.0.0 to ≥ 1.1.0 (manifest already allows it: `from: "1.0.0"`; `Package.resolved` must be updated). `specs/implementation_plan.md` L135 says centroids are "now exposed" while `specs/architecture.md` L392 still says not exposed in v1.0.0 — both are right for their version; the pin is the gap.

## 7. Free tier and licensing

- `argmax-oss-swift` code: MIT ([LICENSE](https://github.com/argmaxinc/argmax-oss-swift/blob/v1.1.1/LICENSE)). Prior research notes vendored Hub/Tokenizers sources under Apache-2.0 (`NOTICES`).
- SpeakerKit models: [`argmaxinc/speakerkit-coreml`](https://huggingface.co/argmaxinc/speakerkit-coreml) — HF API reports `gated: false`, `private: false`, `license: cc-by-4.0`, last modified 2026-09-13. Model card: "SpeakerKit the Swift framework has MIT license. The models SpeakerKit is built on have CC BY 4 license." CC-BY-4.0 carries an **attribution** obligation (flag for the user; legal call is theirs).
- Free vs Pro: the upstream README says SpeakerKit "runs Pyannote v4 (community-1)"; the [Argmax SDK 2 post](https://www.argmaxinc.com/blog/argmax-sdk-2) (2026-04-07) says Argmax "open-sourced SpeakerKit's pyannote 4 engine" while Pro moved to Nvidia Sortformer. The [Open-source vs Pro](https://app.argmaxinc.com/docs/wiki/open-source-vs-pro-sdk) page lists file-based diarization in open source; real-time transcription with speakers is Pro.
- **Dropping WhisperKit changes nothing here**: SpeakerKit's download/config path is independent (`PyannoteConfig(downloadBase:modelRepo: "argmaxinc/speakerkit-coreml")`), no token needed. v1.1.1 stopped reading HF tokens from disk — irrelevant for this public, ungated repo.

## 8. Version notes relevant to the swap

- v1.1.0 also lists "Bug fixes for `promptTokens`" (possibly relevant to the custom-vocab blocker, out of scope here) and WhisperKit incremental file loading.
- v1.1.0 changed the macOS segmenter variant selection (W8A16 now requires macOS 15 on device; Biscotti is macOS 15+, so no effect) — `git diff v1.0.0 v1.1.1 -- Sources/SpeakerKit/Pyannote/PyannoteConfig.swift`.
- SpeakerKit diff v1.0.0→v1.1.1: 9 files, +195/−31, from two commits (#463 centroids, #495 model-load hardening). No change to `addSpeakerInfo`.
