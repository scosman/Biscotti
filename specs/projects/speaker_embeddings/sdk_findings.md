---
status: complete
---

# SDK & Codebase Findings — Speaker Embeddings

Pre-spec research for the voiceprint project. Everything below was **verified
against the actual source and the actual downloaded CoreML models**, not from
memory or documentation.

- SDK: `argmax-oss-swift` @ `1e2a163` ("Release v1.1.0"), checked out at
  `Packages/Transcription/.build/checkouts/argmax-oss-swift`.
- Models: `~/Library/Application Support/Biscotti/models/argmaxinc/speakerkit-coreml`
  (`speaker_embedder/pyannote-v3/W8A16`, `speaker_clusterer/pyannote-v4/W32A32`,
  `speaker_segmenter/pyannote-v3/W8A16`).

Anything that contradicts `specs/research/argmax/README.md` is called out at the
bottom so that doc can be corrected.

---

## 1. What the embeddings actually are

### Dimension: 256 floats

From `SpeakerEmbedder.mlmodelc/metadata.json`:

| Model | Input | Output |
|---|---|---|
| `SpeakerEmbedder` | `preprocessor_output_1 [1, 2998, 80]`, `speaker_masks [1, 64, 1767]` | **`speaker_embeddings [1, 64, 256]`** Float16 |
| `PldaProjector` | `embeddings [1, 64, 256]` | `plda_embeddings [1, 64, 128]` Float16 |

So a centroid is **256 `Float`s ≈ 1 KB** stored as Float32. The 128-dim PLDA
projection is a *separate* model used only inside VBx clustering; it never
escapes the SDK. `speakerCentroidEmbeddings` is built from
`SpeakerEmbedding.embedding` (the raw 256-dim), confirmed at
`VBxClustering.swift:232`.

**Storage is a non-issue.** One centroid per speaker per meeting. 1,000 meetings
× 3 speakers ≈ 3,000 centroids ≈ **3 MB**. The user's "in-memory scan, no index"
call is correct by a wide margin — a full 3,000-way cosine scan of 256-dim
vectors is well under a millisecond with `vDSP`.

### Unnormalised and mean-pooled — confirmed

`VBxClustering.centroidsFromFinalAssignments` (lines 217–252) does a plain
arithmetic mean of member embeddings, then divides by the count. **No
normalisation anywhere.** The research bot's warning is correct and load-bearing:
when averaging centroids from several meetings into one enrollment, L2-normalize
each centroid first or the loudest/longest meeting dominates.

### Distance convention: `[0, 2]`, and it is a *distance* — confirmed

`MathOps.cosineDistance` = `1 - cosineSimilarity`, clamped to `[0, 2]`.
Zero-magnitude vectors return the sentinel `1.0` (not an error) — a silent
"orthogonal" that must never be mistaken for a real measurement. Guard against
zero-magnitude stored vectors explicitly.

### How many windows feed a centroid

Derived from the segmenter model shapes (`waveform [480000]`,
`sliding_window_waveform [21, 1, 160000]`, `speaker_activity [21, 3]`):

- Chunk = **30 s** (480,000 @ 16 kHz).
- Window = **10 s**, 21 windows per chunk → stride ≈ **1 s**.
- Up to **3 local speakers** per window; embedder handles up to 64 speaker slots
  per chunk.

A 30-minute meeting therefore mean-pools on the order of **10³ window
embeddings** per speaker centroid. Centroids are consequently quite stable
*within* a file. The cross-file variance we care about comes from mic, room,
codec, and the speaker's own vocal state — not from sampling noise.

**Corollary:** a speaker who says 15 words in a 45-minute meeting produces a
centroid pooled from very few windows. Enrollment quality varies enormously by
speaking time, and we should record speaking duration alongside each centroid
so low-evidence voiceprints can be down-weighted.

---

## 2. Threshold calibration — we have a real anchor

The SDK genuinely refuses to define a same-speaker threshold (docstring on
`speakerCentroidEmbeddings`). But it *does* ship one for the intra-file case:

```swift
// VBxClustering.swift
private static let defaultThreshold: Float = 0.6   // AHC linkage cut
```

applied to **L2-normalized** embeddings (`VBxClustering.swift:56–64`), and
exposed as `PyannoteDiarizationOptions.clusterDistanceThreshold`.

So **0.6 is Argmax's own "same speaker, same recording" operating point.** That
is a defensible starting anchor, with two caveats:

1. It's a *linkage* cut over normalized vectors, not a centroid-to-centroid
   comparison; not identical semantics.
2. Cross-recording is a strictly harder problem than intra-recording (different
   mic, room, codec, day). The cross-file threshold will likely need to be
   **tighter** than 0.6 to hold false-accept rate down, at the cost of recall.

The project should ship with 0.6 as the documented starting point and then do
what the research bot suggests: **log distances against user confirmations and
rejections, and pick the operating point off our own data.** We already have the
confirm/correct UI and the `userSet` provenance flag needed to build that
labelled set (see §4).

## 3. `centroidSource` — a real fork with a real trap

```swift
public enum SpeakerCentroidSource {
    case finalAssignment   // default
    case trainableOnly
}
```

`.trainableOnly` keeps only embeddings where
`nonOverlappedFrameRatio > minActiveRatio` (default **0.2**) — i.e. windows
where the speaker is at least 20% non-overlapped. Purer enrollment, and for a
voiceprint DB that is what we want.

**The trap is real and confirmed** (`VBxClustering.swift:229–231`): the filter is
applied *after* cluster assignment, so a speaker whose every window is heavily
overlapped gets **no key at all** in `speakerCentroidEmbeddings`, while still
appearing in `segments`. `if let`, never `[id]!`.

Note also that `PyannoteDiarizationOptions` is plumbed through
`SpeakerKit.diarize(audioArray:options:progressCallback:)`, and
`InProcessTranscriptionEngine.runDiarization` currently calls the **no-options**
overload — so switching `centroidSource` is a change we can make, but it is a
change to the diarization call, and it goes through the XPC boundary.

**Design implication:** the two sources are not mutually exclusive. We could
request `.trainableOnly` for the *enrollment* write and fall back to
`.finalAssignment` for speakers it drops — but that needs two diarization runs,
which is expensive. More likely: pick one, and treat a missing centroid as "this
speaker has no voiceprint this meeting," which is a perfectly acceptable outcome.

## 4. Where Biscotti stands today

### The embeddings are computed, then thrown away

`InProcessTranscriptionEngine.swift:271`:

```swift
speakerEmbeddings: [:],   // ← hardcoded empty
```

`TranscriptResult.speakerEmbeddings: [Int: [Float]]` already exists, is already
`Codable`, and already has round-trip tests
(`ResultCodableTests.speakerEmbeddingsCodable`). The XPC transport is JSON-encoded
`TranscriptResult`, so it carries the field with no protocol change. The
CLI (`OutputFormatting.swift:66`) already prints them when non-empty.

So step one is genuinely small: pass `diarization.speakerCentroidEmbeddings`
through instead of `[:]`. Everything downstream of that is new work.

### Nothing persists them

`TranscriptRecord` has no embeddings field. It does have the established pattern
for adding one: JSON-encoded `Data` + a `@Transient` computed accessor, because
**SwiftData cannot materialize generic `Array<String>` from on-disk stores in SPM
modules** (see the comment on `vocabularyUsedData`). A `[Int: [Float]]` would hit
the same problem, so it must follow the same `Data`-backed pattern.

`Person` carries a standing note: *"Reserved for P2: voiceprint/centroid
embeddings, an `isMe` flag."* This project is that P2.

### Confirmed-vs-inferred already exists — no new concept needed

The user asked whether we're clear on this. We are:

```swift
public struct SpeakerAssignmentEntry: Codable, Equatable, Sendable {
    public let personID: UUID
    public let userSet: Bool     // true = human assigned; false = LLM inferred
}
```

`DataStore.setSpeakerAssignments` (the LLM path) **refuses to overwrite any entry
with `userSet == true`**, and `setSpeakerAssignment` (the manual path) always
writes `true`. `humanSetSpeakerMappings` already returns only the confirmed ones.

This is exactly the confirmed/inferred weighting signal the matching algorithm
needs, and it is already persisted per transcript. It is also the labelled data
we need for threshold calibration.

### The "many entries per person" problem is real, and it's upstream

`DataStore.findOrCreatePerson(name:email:)` matches by **email
(case-insensitive) if an email is given, otherwise by exact name**. It never
reconciles the two. So typing "Mike" once and "mike@kiln.tech" another time
creates **two distinct `Person` rows** — precisely the case flagged in the
overview. The voiceprint store has to tolerate several `Person` rows being the
same human, and the matching report should surface that to the LLM rather than
try to resolve it silently.

### The LLM insertion point is clean

`IntelligencePrompts.analysisFirstUser` assembles XML blocks in order:

```
<meeting_details>            ← title, date, location, invitees (name + email)
<user_speaker_person_mapping>  ← confirmed assignments only, "id | name | email"
<transcript>
speakerTaskInstructions
```

Adding a `<voiceprint_matches>` block is additive and idiomatic. The output
contract is already `<speakerIndex> | <Full Name> | <email-or-blank>` lines,
parsed by `SpeakerMappingParser` — so the LLM can already express "Speaker 1 is
steve@kiln.tech" without a format change. `speakerTaskInstructions` will need
new wording telling the model how to weigh voiceprint evidence against transcript
evidence.

The invitee list (with emails) is *already* in the prompt, which supports the
overview's "report based on emails" idea directly.

## 5. Versioning: the sharp edge nobody has flagged yet

The embedder model is versioned **`pyannote-v3`, variant `W8A16`**
(`ModelInfo.embedder`), and the variant is chosen *at runtime by OS version*:

```swift
let variant = variant ?? {
    if #available(iOS 17, macOS 14, *) { return "W8A16" } else { return "W16A16" }
}()
```

Embeddings are only comparable within the same embedder version **and quantization
variant**. If Argmax bumps the embedder to pyannote-v4, or a user's machine
resolves a different variant, **every stored voiceprint silently becomes
garbage** — and the failure mode is not a crash, it's quietly wrong people's
names on transcripts.

Every stored embedding must therefore be stamped with an embedding-space
identifier (embedder version + variant, and probably our own
`transcriptionMethodId`), and matching must refuse to compare across spaces.
This is cheap to do now and impossible to retrofit onto unstamped data.

## 6. Limits worth knowing

- **No API to embed an arbitrary clip.** `SpeakerEmbedding` is internal; only
  per-cluster centroids escape. There is no "give me a voiceprint for this 5
  seconds of audio" call.
  - Partial workaround: `PyannoteDiarizationOptions.clipTimestamps` accepts
    `[start, end]` pairs, so you *can* diarize a sub-range and take its centroid.
    Costs a full diarization pass.
  - Consequence: **enrollment happens as a side effect of transcription.** There
    is no cheap "record 10 seconds to enroll your voice" onboarding flow without
    running the diarizer over that clip.
- **Per-window embeddings are not exposed**, so we cannot do our own outlier
  trimming *within* a meeting's cluster. The overview's "trim outliers" idea can
  only operate **across** meetings — over the set of per-meeting centroids
  belonging to one identity. That is still worth doing (one bad meeting centroid
  shouldn't poison an enrollment), but it's a coarser tool than it sounds.
- **Cost is already paid.** Centroids come back from a diarization run we already
  do. Capturing them adds no inference time.

## 6b. PLDA: the transform the centroids skip

SpeakerKit computes two vectors per (window, local speaker), in
`SpeakerEmbedderModel` (`SpeakerEmbedding.embedding` and `.pldaEmbedding`):

| Vector | Dim | Made by | Used for |
|---|---|---|---|
| Raw | 256 | `SpeakerEmbedder` (pyannote-v3 / W8A16) | AHC linkage (L2-normalized, threshold 0.6); **the exposed centroids** |
| PLDA | 128 | `PldaProjector` CoreML model (pyannote-v4 / W32A32), applied to the raw output | VBx clustering only |

The whole transform is inside the CoreML model; there is no Swift-side math to
copy. In pyannote it is: center, LDA, length-normalize, center again, then the
PLDA rotation/whitening. Its purpose is to separate speaker identity from
channel (mic, room, codec) variation — the hard part of matching across
recordings. Per-window PLDA vectors exist in memory but are never averaged or
exposed. Upstream `main` (checked 2026-09-30) and the latest release (v1.1.0)
have no PLDA centroids. This project adds them via a fork + upstream PR (see
`architecture.md` §2).

Cosine distance in the PLDA space is a common approximation of proper PLDA
scoring (a log-likelihood ratio). Which space works better on our data is an
empirical question for `voiceprint-cli metrics`.

## 7. Corrections for `specs/research/argmax/README.md`

| Location | Says | Should say |
|---|---|---|
| §3 SpeakerKit types | `nearestSpeakerCentroid(to:) -> Int?` | `-> (speakerId: Int, distance: Float)?` |
| §6 / §7 Gotcha 7 | centroid embeddings "not public in v1.0.0" | Correct, but the doc should now record the concrete facts: **256-dim**, raw/unnormalised, `[0,2]` distance, `.trainableOnly` may omit speakers |
| Recommendation → `TranscriptResult` | `speakerEmbeddings` "reserved; empty in v1.0.0" | Still empty, but now for a Biscotti reason (hardcoded `[:]`), not an SDK limitation |
| §6 Recommendation | "compare centroid embeddings against a saved known-speakers table" | Add the **embedding-space versioning** requirement (§5) |

These are documentation fixes; folding them in is in scope for this project.
