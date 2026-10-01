---
status: complete
---

# Architecture: Speaker Embeddings (Voiceprint Database)

Inputs: [`functional_spec.md`](functional_spec.md) (behavior),
[`sdk_findings.md`](sdk_findings.md) (SDK facts). This doc decides where each
part lives, the types and signatures, the algorithms, and the tests.

---

## 1. Overview

```
 argmax-oss-swift (fork)              Transcription (package)
 ───────────────────────              ─────────────────────────────────────
 DiarizationResult                    InProcessTranscriptionEngine
   .speakerCentroidEmbeddings (raw)     diarize(.trainableOnly)
   .speakerPLDACentroidEmbeddings ◄──   → TranscriptResult
     (NEW, upstream PR)                     .embeddingSets [raw, plda]   (replaces speakerEmbeddings)
                                            .speakerSpeechDurations
                                      SpeakerAnalyzer (new, in-process, CLI only)

 BiscottiKit
 ─────────────────────────────────────────────────────────────────────────────────
 TranscriptionService ──addTranscript──► DataStore
                                           Voiceprint (@Model, new; one row per speaker per kind)
                                           CalendarSnapshot.currentUserPersonID (new)
                                           voiceprintQuery / voiceprintCorpus / backfill reads
                                                    │
 Intelligence.runAnalysisSession                    │
   └─ VoiceprintEvidence ◄──────────────────────────┘
        ├─ VoiceprintMatching.VoiceprintMatcher (new module, pure)
        └─ VoiceprintReport.render → <voiceprint_matches> → MeetingAnalyzer speaker turn

 MeetingDetailUI (#if DEBUG) ── right-click speaker ──► Intelligence.voiceprintDebug ──► VoiceprintDebugView

 voiceprint-cli (new executable)
   backfill → SpeakerAnalyzer + BackfillSpeakerMapper → DataStore.addVoiceprints
   metrics  → DataStore corpus → VoiceprintEvaluator → MetricsFormatter
```

### Changed and new code

| Location | Change |
|---|---|
| `argmax-oss-swift` fork | Add `speakerPLDACentroidEmbeddings`. Upstream PR. |
| `Packages/Transcription` | Depend on the fork. Replace `speakerEmbeddings` with `embeddingSets` (raw + PLDA). Add `speakerSpeechDurations`. `.trainableOnly`. New `SpeakerAnalyzer`. |
| `BiscottiKit/DataStore` | New `Voiceprint` model; `currentUserPersonID` on `CalendarSnapshot`; voiceprint reads and writes. |
| `BiscottiKit/VoiceprintMatching` | **New module.** Pure logic: vector math, matcher (+ explain), backfill speaker mapping, evaluator, metrics text. Depends only on `DataStore` (for DTO types). |
| `BiscottiKit/Intelligence` | Report rendering, evidence builder, prompt changes, wiring, `#if DEBUG` debug report. |
| `BiscottiKit/AppCore` | `persistSnapshot` passes the current-user person. |
| `BiscottiKit/MeetingDetailUI` | `#if DEBUG` right-click entry and `VoiceprintDebugView`. |
| `BiscottiKit/voiceprint-cli` | **New executable target.** `backfill`, `metrics`. |
| `BiscottiKit/Tests/IntelligenceAITests` | **New gated test target** for prompt behavior with a real LLM. |
| `Makefile` | `test-ai` also runs `IntelligenceAITests`. |

### Why a separate `VoiceprintMatching` module

The matcher, the evaluator, and the backfill mapper are pure functions over
value types. `Intelligence` (app and debug window) and `voiceprint-cli` (dev
tool) both need them. In `Intelligence`, the CLI would depend on the LLM stack;
in `DataStore`, algorithms would live in the persistence layer. A small module
with one dependency (`DataStore`, for its `Sendable` DTOs) is the clean
boundary, and it is fully unit-testable with synthetic vectors.

---

## 2. SpeakerKit fork

### 2.1 The change

Repository: the developer's existing fork, `scosman/WhisperKit`, renamed to
`scosman/argmax-oss-swift` and synced with upstream first (§2.2 step 1). Two
branches:

| Branch | Base | Use |
|---|---|---|
| `biscotti/v1.1.0-plda-centroids` | tag `v1.1.0` | What Biscotti pins (exact commit). Minimal diff from the version we use today. |
| `plda-centroid-embeddings` | upstream `main` | The upstream pull request. Same change, rebased. |

Code change (both branches), all in `Sources/SpeakerKit`:

1. **`Pyannote/VBxClustering.swift`** — generalize
   `centroidsFromFinalAssignments` with a vector selector:

   ```swift
   func centroidsFromFinalAssignments(
       assignments: [Int], embeddings: [SpeakerEmbedding],
       source: SpeakerCentroidSource, minActiveRatio: Float,
       vector: (SpeakerEmbedding) -> [Float]? = { $0.embedding }
   ) -> [Int: [Float]]
   ```

   Same loop; a member whose `vector(...)` is nil or empty is skipped (exactly
   like an empty raw embedding today). `cluster(...)` calls it twice — once with
   the default (raw), once with `{ $0.pldaEmbedding }` — and returns both maps
   (`pldaCentroids` as a fourth tuple element).
2. **`Pyannote/SpeakerClustering.swift`** — `ClusteringResult` gains
   `speakerPLDACentroids: [Int: [Float]]` (defaulted `[:]` in its init).
3. **`Pyannote/PyannoteDiarizer.swift`** — `postProcess(...)` takes and passes
   `speakerPLDACentroids` to `DiarizationResult`.
4. **`DiarizationResult.swift`** —

   ```swift
   /// Per-speaker centroid embeddings in the PLDA-projected space (128-dim for
   /// pyannote-v4), keyed by `speakerId`. Mean of the per-window PLDA embeddings
   /// under the same final labels and the same `centroidSource` filter as
   /// ``speakerCentroidEmbeddings``. Empty when the backend has no PLDA stage.
   /// A speaker can be absent; use `if let`.
   public private(set) var speakerPLDACentroidEmbeddings: [Int: [Float]]
   ```

   Both initializers gain `speakerPLDACentroidEmbeddings: [Int: [Float]] = [:]`.
   `centroidCosineDistance` / `nearestSpeakerCentroid` stay raw-only — a minimal
   PR is easier to accept.
5. **Tests** — `Tests/SpeakerKitTests/SpeakerCentroidEmbeddingsTests.swift`
   (XCTest): mirror the synthetic-data tests for PLDA —
   `centroidSource` filter honored, cluster with no trainable members omitted,
   value equals the mean of the members' `pldaEmbedding`, nil `pldaEmbedding`
   members skipped, generic init accepts the new map.

The PLDA centroid is a plain mean, like the raw centroid. Biscotti normalizes
before comparing (§5.2).

### 2.2 Process

1. **Use the existing fork.** The developer already has a fork under the
   repository's old name, `https://github.com/scosman/WhisperKit` (about two
   years old; `main` at `228630c` on 2026-09-30, upstream `main` at `f4e5d6b`).
   Do not create a new fork.
   1. **Bring it up to date first:** sync the fork's `main` with upstream
      `argmaxinc/argmax-oss-swift` `main` (`gh repo sync scosman/WhisperKit
      --source argmaxinc/argmax-oss-swift --branch main`, or fetch upstream
      and push), and fetch upstream tags (needed for `v1.1.0`). If the fork's
      `main` has commits that upstream does not have, stop and ask the developer
      before overwriting them.
   2. **Rename it to `argmax-oss-swift`** (`gh repo rename`). SwiftPM derives a
      package's identity from the last URL path component, so a URL ending in
      `WhisperKit.git` makes the identity `whisperkit`, and every
      `.product(name:package: "argmax-oss-swift")` reference would fail to
      resolve. GitHub redirects the old name.
   **Both are public actions: confirm with the developer first.** `gh` must run
   outside the Bash sandbox (user `CLAUDE.md`).
2. Clone to a directory **outside** this repo (for example
   `~/Dropbox/workspace/misc/argmax-oss-swift`). Create the `v1.1.0` branch,
   make the change, run the SDK unit tests for `SpeakerCentroidEmbeddingsTests`
   (outside the sandbox; `swift test` fails inside it). The synthetic-data tests
   need no models; tests that need models can be skipped.
3. Push the branch (confirm first). Record the commit SHA.
4. `Packages/Transcription/Package.swift`:

   ```swift
   // TEMPORARY: fork with speakerPLDACentroidEmbeddings (upstream PR: <url>).
   // Return to argmaxinc/argmax-oss-swift once a release contains it.
   .package(url: "https://github.com/scosman/argmax-oss-swift.git", revision: "<sha>"),
   ```

   The package identity stays `argmax-oss-swift`, so every
   `.product(name:package:)` reference is unchanged. Re-resolve, so
   `Packages/Transcription/Package.resolved` and
   `Packages/BiscottiKit/Package.resolved` point at the fork.
   `experiments/ArgMaxKit` is disposable and is not changed.
5. Create the `main`-based branch, push, and open the PR. **Confirm first.**
   Contributor-agreement decisions belong to the developer; do not accept any
   agreement or make claims on the developer's behalf.
6. Add a `CLAUDE.md` gotcha: SpeakerKit is pinned to a fork, why, and the
   condition to return to upstream.

---

## 3. Transcription package

### 3.1 `TranscriptResult` changes

```swift
public enum EmbeddingKind: String, Sendable, Codable, CaseIterable { case raw, plda }

/// One kind of per-speaker centroid vectors from one diarization run.
public struct SpeakerEmbeddingSet: Sendable, Codable, Equatable {
    public let kind: EmbeddingKind
    /// Embedding space key, see `SpeakerEmbeddingSpace`.
    public let space: String
    /// Raw (not normalized) vectors by diarization speaker ID. Speakers can be absent.
    public let vectors: [Int: [Float]]
}

public struct TranscriptResult: Sendable, Codable, Identifiable, Equatable {
    // existing fields unchanged, EXCEPT:
    // REMOVED: public let speakerEmbeddings: [Int: [Float]]
    public let embeddingSets: [SpeakerEmbeddingSet]          // NEW
    /// Sum of each diarization speaker's time ranges, in seconds.
    public let speakerSpeechDurations: [Int: TimeInterval]   // NEW

    public init(
        id: UUID = UUID(), createdAt: Date = Date(),
        transcriptionMethodId: String, language: String, speakerCount: Int,
        segments: [TranscriptSegment],
        embeddingSets: [SpeakerEmbeddingSet] = [],
        speakerSpeechDurations: [Int: TimeInterval] = [:],
        processingDuration: TimeInterval
    )
}
```

`speakerEmbeddings` is removed rather than kept next to `embeddingSets`: two
fields for the same data would drift. It was always empty, so nothing reads it.
The ~40 call sites in tests that pass `speakerEmbeddings: [:]` lose that
argument (mechanical). `ResultCodableTests` and `CLIOutputTests` are rewritten
for the new shape; `transcribe-cli`'s `OutputFormatting` prints each set as
`kind (space): N speakers × D dims` instead of raw vectors.

Synthesized `Codable` is fine: `TranscriptResult` is decoded only from JSON
made by the same build (XPC reply, tests).

`TranscriptSanitizer.sanitize` rebuilds `TranscriptResult` field by field.
**It must pass `embeddingSets` and `speakerSpeechDurations` through**, or they
are silently lost. Test it.

### 3.2 Embedding space

```swift
public enum SpeakerEmbeddingSpace {
    /// Raw: "<embedder version>/<embedder variant>", e.g. "pyannote-v3/W8A16".
    /// PLDA: raw key + "+plda:<plda version>/<plda variant>",
    ///       e.g. "pyannote-v3/W8A16+plda:pyannote-v4/W32A32".
    public static func current(_ kind: EmbeddingKind) -> String
}
```

Reads `ModelInfo.embedder()` and `ModelInfo.plda()` (public extensions in
SpeakerKit; `ModelInfo` is in `ArgmaxCore` — add `import ArgmaxCore`, which is
visible transitively through the SpeakerKit product). These are the same calls
`PyannoteModelManager` uses as defaults, so the key describes the models that
actually ran. Nil components render as `"unknown"`. The dimension is not in
the key; it is stored and checked per voiceprint.

### 3.3 Speech durations

```swift
enum SpeakerDurations {
    /// (speakerID, start, end) triples → total seconds per speaker.
    static func compute(_ spans: [DiarizedSpan]) -> [Int: TimeInterval]
    /// diarization.segments → spans; segments with a nil `speaker.speakerId` are skipped.
    static func spans(from diarization: DiarizationResult) -> [DiarizedSpan]
}

public struct DiarizedSpan: Sendable, Codable, Equatable {
    public let speakerID: Int; public let start: TimeInterval; public let end: TimeInterval
}
```

Pure; `compute` is tested with plain spans. No audio access.

### 3.4 Engine changes

```swift
enum DiarizationSettings {
    static let options = PyannoteDiarizationOptions(centroidSource: .trainableOnly)
}

enum EmbeddingSetBuilder {
    /// Builds [raw, plda] sets; drops empty vectors; omits a set with no vectors.
    static func build(from diarization: DiarizationResult) -> [SpeakerEmbeddingSet]
}
```

- `runDiarization` calls `speaker.diarize(audioArray:options: DiarizationSettings.options)`.
- `assembleResult` sets `embeddingSets: EmbeddingSetBuilder.build(from: diarization)`
  and `speakerSpeechDurations: SpeakerDurations.compute(SpeakerDurations.spans(from: diarization))`.

Centroid dictionaries are read only by iteration; no subscript-and-force.

### 3.5 `SpeakerAnalyzer` (new, public, in-process only)

Used only by `voiceprint-cli backfill`. Diarization without STT.

```swift
public actor SpeakerAnalyzer {
    public init()
    /// Downloads SpeakerKit models into ModelStorage if missing.
    public func ensureModelsDownloaded() async throws
    public func analyze(micPath: String, systemPath: String) async throws -> SpeakerAnalysis
    public func unload() async
}

public struct SpeakerAnalysis: Sendable, Equatable {
    public let embeddingSets: [SpeakerEmbeddingSet]
    public let speakerSpeechDurations: [Int: TimeInterval]
    public let spans: [DiarizedSpan]
}
```

No XPC path: the app never calls it, so `TranscriptionEngine`,
`TranscriberServiceProtocol`, and `XPCEngineAdapter` do not change.

To avoid copies, move from `InProcessTranscriptionEngine`'s private extensions
to internal shared helpers used by both types:
`AudioLoading.loadSamples(fromPath:)` (current `loadAudioSamples`, same errors),
`AudioLoading.loadAndMerge(micPath:systemPath:) -> MergeResult`, and
`SpeakerKitConfigFactory.make(download:load:) -> PyannoteConfig` (current
`makeSpeakerConfig`).

### 3.6 Manual-test staleness

This project touches `Packages/Transcription`. Per `CLAUDE.md`, mark every
recordable `tx_*` step `not-run` in `ManualTestApp/Results/manual_test_results.json`
in the phase that changes the package.

---

## 4. DataStore

### 4.1 Models

`Models/Voiceprint.swift`:

```swift
/// One speaker's voiceprint of one kind, from one transcript. Does NOT store a
/// person: identity is resolved at read time from the owning transcript's
/// `speakerAssignments[speakerID]` (functional spec §3.2).
@Model public final class Voiceprint {
    public var id = UUID()
    public var createdAt = Date()
    public var speakerID: Int = 0
    /// `VoiceprintKind.rawValue` ("raw" | "plda").
    public var kindRaw: String = VoiceprintKind.raw.rawValue
    public var embeddingSpace: String = ""
    public var dimension: Int = 0
    /// Raw (not normalized) vector, little-endian Float32. `Data`, not `[Float]`:
    /// SwiftData cannot materialize collections from on-disk stores in SPM modules.
    public var vectorData = Data()
    public var speakingDuration: Double = 0
    public var transcript: TranscriptRecord?
    public init(speakerID: Int, kind: VoiceprintKind, embeddingSpace: String,
                vector: [Float], speakingDuration: Double)
}

/// DataStore's own copy of the kind, so read models do not expose Transcription types.
public enum VoiceprintKind: String, Sendable, Codable, CaseIterable { case raw, plda }
```

`TranscriptRecord` gains:

```swift
@Relationship(deleteRule: .cascade, inverse: \Voiceprint.transcript)
public var voiceprints: [Voiceprint] = []
```

`CalendarSnapshot` gains `public var currentUserPersonID: UUID?`.

`DataStoreSchemaV1.models` adds `Voiceprint.self`. All changes are additive
with defaults, which `DataStore.init`'s comment says SwiftData migrates
automatically. An on-disk round-trip test (§10) guards the materialization
risk.

### 4.2 Vector coding

```swift
enum VectorCoding {
    static func encode(_ vector: [Float]) -> Data          // little-endian Float32
    /// Nil if `data.count != dimension * 4` or any value is not finite.
    static func decode(_ data: Data, dimension: Int) -> [Float]?
}
```

### 4.3 Writes

- **`addTranscript`** (existing): in the same save, for each set in
  `result.embeddingSets` and each `(speakerID, vector)` with a non-empty,
  all-finite vector, insert a `Voiceprint` (kind mapped from `EmbeddingKind`,
  duration = `result.speakerSpeechDurations[speakerID] ?? 0`) and append it to
  `record.voiceprints`. Skip and log non-finite vectors.
- **`setParticipants(_:organizer:currentUser:for:)`** — new parameter
  `currentUser: UUID? = nil` (defaulted). Sets
  `meeting.calendarSnapshot?.currentUserPersonID = currentUser`. Throws
  `notFound` if non-nil and no Person exists (same rule as the organizer).
- **Backfill:**

  ```swift
  public struct NewVoiceprint: Sendable, Equatable {
      public let speakerID: Int; public let vector: [Float]; public let speakingDuration: Double
  }
  func addVoiceprints(_ items: [NewVoiceprint], kind: VoiceprintKind, space: String,
                      to transcriptID: UUID) throws
  func hasVoiceprints(transcriptID: UUID, kind: VoiceprintKind, space: String) throws -> Bool
  ```

### 4.4 Reads (`DataStore+Voiceprints.swift`)

```swift
public struct SpeakerTagData: Sendable, Equatable { public let personID: UUID; public let userSet: Bool }

public struct VoiceprintData: Sendable, Equatable {
    public let meetingID: UUID
    public let meetingTitle: String
    public let meetingDate: Date
    public let transcriptID: UUID
    public let speakerID: Int
    public let vector: [Float]               // raw, decoded
    public let speakingDuration: Double
    public let tag: SpeakerTagData?          // nil = no tag, or tagged person no longer exists
}

public struct VoiceprintCorpusData: Sendable, Equatable {
    public let kind: VoiceprintKind
    public let space: String
    public let entries: [VoiceprintData]
    public let people: [UUID: PersonData]    // every person referenced by a tag
}

public struct VoiceprintQueryData: Sendable, Equatable {
    public let space: String?                // nil when the transcript has no voiceprints of this kind
    public let vectors: [Int: [Float]]
    public let speakingDurations: [Int: Double]
}

func voiceprintQuery(transcriptID: UUID, kind: VoiceprintKind) throws -> VoiceprintQueryData?
func voiceprintCorpus(kind: VoiceprintKind, space: String,
                      excludingMeetingID: UUID?) throws -> VoiceprintCorpusData
```

`voiceprintCorpus` algorithm:

1. Fetch all `Person` rows once → `[UUID: Person]`.
2. Fetch all `Meeting`s. Skip the excluded meeting and meetings with no
   `preferredTranscriptID`. Resolve the preferred `TranscriptRecord` from
   `meeting.transcripts` (`TranscriptRecord` has no back-reference to
   `Meeting`, so the walk starts from meetings).
3. Decode `record.speakerAssignments` once per record.
4. For each voiceprint in `record.voiceprints` with matching `kindRaw` and
   `embeddingSpace`: decode the vector (skip on nil, debug log); tag = the
   assignment for `speakerID` if its person exists, else nil.
5. `people` = `PersonData` for every person referenced by a tag.

A few thousand rows, one pass, no N+1 fetches.

Backfill reads:

```swift
public struct StoredSpanData: Sendable, Equatable {
    public let speakerID: Int; public let start: TimeInterval; public let end: TimeInterval
}
public struct BackfillCandidateData: Sendable, Equatable {
    public let meetingID: UUID; public let title: String; public let date: Date
    public let transcriptID: UUID
    public let micURL: URL?; public let systemURL: URL?      // present files only
    public let segments: [StoredSpanData]                   // segments with a speakerID
}
/// Meetings with a preferred transcript, oldest first.
func backfillCandidates() throws -> [BackfillCandidateData]
```

### 4.5 Current user in calendar context

`calendarContext(meetingID:)` sets `PersonData.isCurrentUser = (id ==
snapshot.currentUserPersonID)` for the organizer and each attendee, and the
"Not yet populated — always false" comment is removed.

---

## 5. `VoiceprintMatching` module (new)

Target `VoiceprintMatching`, dependencies `["DataStore"]`, uses `Accelerate`.
All public types are `Sendable`. The matcher is synchronous and pure; callers
run it off the main actor.

### 5.1 Configuration

```swift
public struct KindThresholds: Sendable, Equatable {
    public var acceptRadius: Float      // R
    public var highDistance: Float
    public var mediumDistance: Float
}

public struct VoiceprintConfig: Sendable, Equatable {
    public var kind: VoiceprintKind = .plda
    /// Raw anchor: SpeakerKit's intra-file clustering threshold (sdk_findings §2).
    public var raw  = KindThresholds(acceptRadius: 0.6, highDistance: 0.35, mediumDistance: 0.50)
    /// No anchor exists for PLDA; same estimates until the calibration pass.
    public var plda = KindThresholds(acceptRadius: 0.6, highDistance: 0.35, mediumDistance: 0.50)
    public var bestMeetingsPerPerson = 5          // K
    public var inferredTagWeight: Float = 0.4
    public var fullSpeechSeconds: Double = 60
    public var inviteeBoost: Float = 1.5
    public var ambiguityScoreRatio: Float = 0.6
    public var ambiguityDistanceGap: Float = 0.05
    public var highMarginRatio: Float = 0.35      // high needs S2 ≤ 0.35·S1
    public var highMinMeetings = 3
    public var highMinConfirmed = 2
    public var mediumMinInferred = 3
    public var unnamedMinMeetings = 2
    public var maxAmbiguousCandidates = 3
    public func thresholds(for kind: VoiceprintKind) -> KindThresholds
    public static let `default` = VoiceprintConfig()
}
```

### 5.2 Vector math

```swift
enum VectorMath {
    /// L2-normalized copy; nil if empty, any value non-finite, or norm == 0.
    static func normalized(_ v: [Float]) -> [Float]?
    /// Cosine distance of two NORMALIZED vectors: clamp(1 − dot, 0, 2). vDSP_dotpr.
    static func distance(_ a: [Float], _ b: [Float]) -> Float
}
```

Zero vectors are rejected at normalization and never reach `distance` — this
avoids SpeakerKit's `1.0` sentinel, which looks like a real measurement.

### 5.3 Prepared corpus

```swift
public struct PreparedCorpus: Sendable {
    public init(_ corpus: VoiceprintCorpusData)   // normalizes; drops entries that fail,
                                                  // and entries whose dimension ≠ the first entry's
    public let kind: VoiceprintKind
    public let space: String
    public let people: [UUID: PersonData]
    public var entryCount: Int { get }
    public var history: HistoryStats { get }      // computed once in init
    func excluding(meetingID: UUID) -> PreparedCorpus     // evaluator
}

public struct HistoryStats: Sendable, Equatable {
    public let meetingCount: Int                 // distinct meetings in the corpus
    public let confirmedMeetingCount: Int        // distinct meetings with ≥1 userSet tag
    public let perPerson: [UUID: PersonHistory]
}
public struct PersonHistory: Sendable, Equatable {
    public let meetings: Int                     // distinct meetings tagged to the person
    public let confirmedMeetings: Int            // …with userSet
}
```

### 5.4 Matcher

```swift
/// `CodingKeyRepresentable` so `[MatchLevel: …]` encodes as a JSON object.
public enum MatchLevel: String, Sendable, Codable, CodingKeyRepresentable {
    case high, medium, low, ambiguous, none
}

public struct PersonCandidate: Sendable, Equatable {
    public let personID: UUID
    public let score: Float
    public let reportedDistance: Float
    public let countedMeetings: Int
    public let confirmedCountedMeetings: Int
    public let isInvitee: Bool
}

public struct SpeakerMatch: Sendable, Equatable {
    public let speakerID: Int
    public let level: MatchLevel
    /// [P1] for high/medium/low; 2…maxAmbiguousCandidates for ambiguous; [] for none.
    public let candidates: [PersonCandidate]
    /// Distinct meetings with an untagged voiceprint inside R.
    public let unnamedMeetingCount: Int
}

public struct Invitees: Sendable, Equatable {
    public let personIDs: Set<UUID>
    public let emails: Set<String>               // lowercased
    public static let none = Invitees(personIDs: [], emails: [])
}

/// Debug detail for one speaker (debug window).
public struct SpeakerExplanation: Sendable, Equatable {
    public let match: SpeakerMatch
    public let allCandidates: [PersonCandidate]  // every person with score > 0, ranked
    public let nearest: [NearestVoiceprint]      // closest N regardless of R
}
public struct NearestVoiceprint: Sendable, Equatable {
    public let meetingTitle: String; public let meetingDate: Date
    public let speakerID: Int
    public let tag: SpeakerTagData?
    public let distance: Float
    public let insideRadius: Bool
    public let speakingDuration: Double
}

public struct VoiceprintMatcher: Sendable {
    public init(config: VoiceprintConfig = .default)
    /// `query` = raw vectors by speaker ID. A vector that fails normalization or the
    /// dimension check → level .none, no candidates.
    public func match(query: [Int: [Float]], corpus: PreparedCorpus,
                      invitees: Invitees) -> [Int: SpeakerMatch]
    public func explain(vector: [Float], speakerID: Int, corpus: PreparedCorpus,
                        invitees: Invitees, nearestCount: Int = 15) -> SpeakerExplanation
}
```

`match` and `explain` share one internal `score(...)` function, so the debug
window shows the production calculation. Thresholds come from
`config.thresholds(for: corpus.kind)`.

**Algorithm for one speaker** (`q` = normalized query vector, `R` = accept radius):

```
hits = []                                      // (entry, d)
for e in corpus.entries:
    d = distance(q, e.vector)
    if d <= R: hits.append((e, d))

untagged = hits where e.tag == nil
unnamedMeetingCount = count of distinct e.meetingID in untagged

for (P, list) in group(hits where e.tag != nil, by: e.tag.personID):
    perMeeting = per meetingID, the entry with smallest d       // one vote per meeting
    kept       = perMeeting sorted by d ascending, first K      // best K
    score = Σ over kept:
              tagW      = e.tag.userSet ? 1.0 : inferredTagWeight
              speechW   = min(1, max(0, e.speakingDuration) / fullSpeechSeconds)
              closeness = 1 − d / R
              tagW * speechW * closeness
    invitee = P ∈ invitees.personIDs || lowercased(people[P]?.email) ∈ invitees.emails
    if invitee: score *= inviteeBoost
    confirmedKept    = kept where userSet
    reportedDistance = min d over confirmedKept, else min d over kept
    candidate(P, score, reportedDistance, kept.count, confirmedKept.count, invitee)

ranked = candidates with score > 0,
         sorted by (score desc, reportedDistance asc, personID.uuidString asc)
```

**Level** (`P1 = ranked[0]`, `P2 = ranked[1]` if any; limits from the kind):

```
if ranked.isEmpty                                   → .none
else if P2 exists and (P2.score >= ambiguityScoreRatio * P1.score
                       or |P1.dist − P2.dist| <= ambiguityDistanceGap)
                                                    → .ambiguous; candidates =
        ranked where score >= ambiguityScoreRatio * P1.score (at least P1 and P2),
        max maxAmbiguousCandidates
else if P1.dist <= highDistance and P1.counted >= highMinMeetings
        and P1.confirmed >= highMinConfirmed
        and (P2 == nil or P2.score <= highMarginRatio * P1.score)
                                                    → .high
else if P1.dist <= mediumDistance and (P1.confirmed >= 1 or P1.counted >= mediumMinInferred)
                                                    → .medium
else                                                → .low
```

`explain.nearest` uses all distances (not only `≤ R`), sorted ascending, first
`nearestCount`, with `insideRadius = d <= R`.

Cost: speakers × entries × dim. 6 × 5,000 × 256 ≈ 7.7 M multiply-adds:
single-digit milliseconds.

### 5.5 Backfill speaker mapping

```swift
public struct SpeakerSpan: Sendable, Equatable {
    public let speakerID: Int; public let start: TimeInterval; public let end: TimeInterval
}

public enum BackfillSpeakerMapper {
    public struct Result: Sendable, Equatable {
        public let mapping: [Int: Int]       // fresh speaker ID → stored speaker ID
        public let unmapped: [Int]           // fresh IDs skipped, sorted
    }
    public static func map(fresh: [SpeakerSpan], stored: [SpeakerSpan],
                           minOverlapFraction: Double = 0.5) -> Result
}
```

1. `overlap[f][s]` = total seconds where fresh speaker `f`'s spans intersect
   stored speaker `s`'s spans (pairwise interval intersection).
2. `freshTotal[f]` = total seconds of `f`'s spans.
3. All pairs with `overlap > 0`, sorted by overlap descending (ties: lower `f`,
   then lower `s`). Greedy one-to-one: accept a pair if neither side is taken
   **and** `overlap[f][s] ≥ minOverlapFraction × freshTotal[f]`.
4. Fresh speakers without an accepted pair are `unmapped`.

### 5.6 Evaluator (metrics)

```swift
public struct VoiceprintEvaluator: Sendable {
    public init(config: VoiceprintConfig = .default,
                sweep: [Float] = stride(from: 0.20, through: 0.90, by: 0.05).map { Float($0) })
    /// Thresholds come from config.thresholds(for: corpus.kind).
    public func evaluate(_ corpus: VoiceprintCorpusData) -> VoiceprintMetrics
}

public struct VoiceprintMetrics: Sendable, Codable, Equatable {
    public struct LevelStats: Sendable, Codable, Equatable { public let total: Int; public let correct: Int }
    public struct SweepRow: Sendable, Codable, Equatable {
        public let radius: Float; public let falseMatchRate: Double; public let missedMatchRate: Double
    }
    public struct ConfusedPair: Sendable, Codable, Equatable {
        public let truth: String; public let predicted: String; public let count: Int
    }
    public struct SuspectTag: Sendable, Codable, Equatable {
        public let person: String; public let meetingTitle: String; public let meetingDate: Date
        public let speakerID: Int; public let distance: Float
    }
    public struct Coverage: Sendable, Codable, Equatable {
        public let peopleWithConfirmed: Int, atLeast3: Int, atLeast5: Int
        public let speechUnder15s: Int, speech15to60s: Int, speech60to300s: Int, speechOver300s: Int
    }
    public let kind: VoiceprintKind
    public let space: String
    public let trials: Int
    public let trialsWithoutHistory: Int
    public let top1Correct: Int
    public let byLevel: [MatchLevel: LevelStats]
    public let sweep: [SweepRow]
    public let equalErrorRadius: Float?
    public let confusedPairs: [ConfusedPair]     // count desc, top 20
    public let coverage: Coverage
    public let suspectTags: [SuspectTag]         // distance desc, top 20
}
```

**Trials — leave one meeting out:**

```
prepared = PreparedCorpus(corpus)
for each meeting M in corpus:
    rest = prepared.excluding(meetingID: M)
    for each entry e in M with e.tag?.userSet == true:
        truth = e.tag.personID
        if rest.history.perPerson[truth] == nil: trialsWithoutHistory += 1; continue
        trials += 1
        m = matcher.match(query: [e.speakerID: e.vector], corpus: rest, invitees: .none)
        correct = (m.level != .none && m.candidates.first?.personID == truth)
        byLevel[m.level] += (1, correct ? 1 : 0); top1Correct += correct
        if m.level != .none and !correct: confused[(name(truth), name(P1))] += 1
        // DET data, independent of R:
        for each tagged person P in rest:
            dist(P) = min distance over P's confirmed entries, else over all P's entries
        genuine.append(dist(truth)); impostors += dist(P) for every P ≠ truth
```

The whole meeting is hidden, not just one voiceprint: other speakers from the
same recording share mic, room, and time, and would leak. Metrics use
`Invitees.none`: they measure the voice signal alone.

**Sweep:** for each radius `r`: `missedMatchRate = |genuine > r| / |genuine|`,
`falseMatchRate = |impostors ≤ r| / |impostors|`. `equalErrorRadius` = the `r`
with the smallest `|falseMatchRate − missedMatchRate|` (nil if no trials).

**Suspect tags:** for each person with confirmed voiceprints in ≥3 meetings:
for each of those voiceprints, the distance to the normalized mean of the
person's **other** confirmed voiceprints; report when it is more than `R`.

Cost: trials × corpus × dim. 3,000 × 3,000 × 128–256 ≈ 1–2.3 G multiply-adds:
a few seconds per kind. Acceptable for a dev tool.

`MetricsFormatter.text(_ results: [VoiceprintMetrics], includeSweep: Bool) -> String`
renders one section per kind, with a short side-by-side summary first (trials,
top-1 accuracy, EER radius per kind). In this module so it is unit-tested.

---

## 6. Intelligence

### 6.1 Prompt changes (`IntelligencePrompts`)

1. `analysisFirstUser` gains `voiceprintBlock: String = ""`, inserted after the
   mapping block and before `<transcript>`; omitted when empty.

   ```swift
   public static func analysisFirstUser(
       detail: MeetingDetailData, human: [Int: PersonData],
       voiceprintBlock: String = "", transcriptSpeakerLabeled: String) -> String
   ```

2. `speakerTaskInstructions`: insert the exact text of functional spec §7.3 as
   a new paragraph after the first paragraph (before the
   `<user_speaker_person_mapping>` paragraph). The output-format text does not
   change.
3. `inviteeBlock`: append ` (the person who recorded this meeting)` to the
   invitee with `isCurrentUser == true`. This reaches every prompt that has
   meeting details.

### 6.2 Report rendering (`VoiceprintReport.swift`, new)

```swift
enum VoiceprintReport {
    /// "" when history.meetingCount == 0.
    static func render(
        unassignedSpeakers: [Int],          // ascending
        speakersWithVector: Set<Int>,
        matches: [Int: SpeakerMatch],
        history: HistoryStats,
        people: [UUID: PersonData],
        invitees: [PersonData],             // organizer first, then attendees (prompt order)
        assignedPersonIDs: Set<UUID>        // persons the user tagged in this transcript
    ) -> String
}
```

Templates (`{p}` = person display; counts use "meeting"/"meetings" correctly):

| Part | Text |
|---|---|
| Person display | `Name <email>`, or `Name (no email)`. Append ` (not invited)` when the meeting has ≥1 invitee and the person is not one. |
| History line | `Voiceprint history: {n} earlier meetings, {c} with names that the user confirmed.` |
| high / medium / low | `Speaker {id}: {High\|Medium\|Low} confidence match to {p}. Heard in {n} earlier meetings, {c} confirmed by the user.` |
| ambiguous | `Speaker {id}: voice is close to more than one known person: {p1} ({n} meetings, {c} confirmed by the user) and {p2} (…).` Three: `{p1} (…), {p2} (…), and {p3} (…)`. |
| none, unnamed ≥ 2 | `Speaker {id}: voice matches an unnamed speaker from {n} earlier meetings.` |
| none | `Speaker {id}: no match to any earlier speaker.` |
| no vector | `Speaker {id}: no voiceprint available for this speaker.` |
| Invitee header | `Invitees with voiceprint history:` |
| Invitee, no history | `{email}: no voiceprint history.` |
| Invitee, best match | `{email}: {n} earlier meetings. Matches Speaker {id}.` (two+: `Matches Speaker 1 and Speaker 3.`) |
| Invitee, only in ambiguous lists | `{email}: {n} earlier meetings. Possible match to Speaker {id}.` |
| Invitee, no match | `{email}: {n} earlier meetings. Matches no speaker in this recording.` |

Assembly: history line, blank line, one line per unassigned speaker, then — if
at least one invitee has an email and is not in `assignedPersonIDs` — blank
line, invitee header, invitee lines. Wrapped in
`<voiceprint_matches>\n…\n</voiceprint_matches>`. No line wrapping.

"Best match" = the invitee is `P1` at high/medium/low for some speaker.
`Speaker {id}` matches the transcript labels: `TranscriptFormatter` prints
`SegmentData.speakerLabel`, which is SpeakerKit's `"Speaker \(id)"`.

### 6.3 Evidence builder (`VoiceprintEvidence.swift`, new)

```swift
struct VoiceprintEvidenceResult: Sendable {
    let corpus: PreparedCorpus
    let queryVectors: [Int: [Float]]
    let invitees: Invitees
    let matches: [Int: SpeakerMatch]
    let block: String
}

enum VoiceprintEvidence {
    /// Throws on store errors. `kind` defaults to config.kind.
    static func compute(store: DataStore, meetingID: UUID, transcript: TranscriptData,
                        detail: MeetingDetailData, human: [Int: PersonData],
                        config: VoiceprintConfig = .default,
                        kind: VoiceprintKind? = nil) async throws -> VoiceprintEvidenceResult

    /// Production entry: never throws; logs and returns "" on any failure.
    static func block(store: DataStore, meetingID: UUID, transcript: TranscriptData,
                      detail: MeetingDetailData, human: [Int: PersonData]) async -> String
}
```

`compute`:

1. `allSpeakers = sorted(Set(transcript.segments.compactMap(\.speakerID)))`;
   `unassigned = allSpeakers − human.keys`.
2. `query = try await store.voiceprintQuery(transcriptID:, kind:)`.
3. If `query?.space` is non-nil: `corpus = try await store.voiceprintCorpus(kind:,
   space:, excludingMeetingID: meetingID)`; else an empty corpus.
4. `invitees` from `detail.calendar` (organizer + attendees; IDs and lowercased emails).
5. In `Task.detached(priority: .userInitiated)`: `PreparedCorpus`, then
   `VoiceprintMatcher.match` for the **unassigned** speakers' vectors.
6. `block = VoiceprintReport.render(…)`.

Logging: `Logger(subsystem: "net.scosman.biscotti", category: "Voiceprints")`;
debug-log the level per speaker and the corpus size. **Never log vectors.**

### 6.4 Wiring

In `Intelligence.runAnalysisSession`:

```swift
let voiceprintBlock = doSpeakers
    ? await VoiceprintEvidence.block(store: store, meetingID: meetingID,
                                     transcript: transcript, detail: detail, human: human)
    : ""
```

computed **once**, then passed to both `buildFirstUserContent` (context
sizing) and `MeetingAnalyzer.Context` (new field `voiceprintBlock: String`), so
the sized prompt and the sent prompt are identical. `MeetingAnalyzer.runSpeakerTurn`
passes `ctx.voiceprintBlock` to `analysisFirstUser`. Persistence of the LLM's
answer does not change. The matcher writes nothing.

`Intelligence` adds the `VoiceprintMatching` dependency.

### 6.5 Debug report (`#if DEBUG`)

`Intelligence+VoiceprintDebug.swift`, whole file in `#if DEBUG`:

```swift
public struct VoiceprintDebugReport: Sendable, Equatable {
    public struct Candidate: Sendable, Equatable, Identifiable {
        public let id: UUID                       // personID
        public let name: String; public let email: String?
        public let score: Float; public let distance: Float
        public let countedMeetings: Int; public let confirmedMeetings: Int
        public let invited: Bool
    }
    public struct Neighbor: Sendable, Equatable, Identifiable {
        public let id: Int                        // rank
        public let meetingTitle: String; public let meetingDate: Date
        public let speakerID: Int
        public let personName: String?            // nil = unnamed
        public let confirmed: Bool?               // nil = unnamed
        public let distance: Float; public let insideRadius: Bool
        public let speakingDuration: Double
    }
    public let speakerID: Int
    public let kind: VoiceprintKind
    public let space: String?
    public let corpusVoiceprints: Int
    public let corpusMeetings: Int
    public let hasVoiceprint: Bool
    public let level: MatchLevel?                 // nil when no voiceprint
    public let candidates: [Candidate]            // explain.allCandidates
    public let neighbors: [Neighbor]              // explain.nearest
    public let llmBlock: String                   // exactly what the speaker turn would send
    public let errorMessage: String?
}

public extension Intelligence {
    func voiceprintDebug(meetingID: UUID, transcriptID: UUID, speakerID: Int,
                         kind: VoiceprintKind) async -> VoiceprintDebugReport
}
```

Implementation: load `meetingDetail` and `transcript(id:)`, `human =
humanSetSpeakerMappings`, run `VoiceprintEvidence.compute(…, kind:)` (so
`llmBlock` is the production block for that kind), then
`VoiceprintMatcher.explain` for `speakerID`'s vector **regardless of whether
the user tagged that speaker**. Errors fill `errorMessage`; the rest are empty.

---

## 7. AppCore

`persistSnapshot` resolves the current user after creating persons:

```swift
// organizer first, then attendees: the first participant with isCurrentUser == true
let currentUserID: UUID? = …   // the pid that findOrCreatePerson returned for that participant
try await store.setParticipants(personIDs, organizer: organizerID,
                                currentUser: currentUserID, for: meetingID)
```

Existing meetings get the value the next time their snapshot is written
(association or correction). No backfill.

---

## 8. Debug window (`MeetingDetailUI`, `#if DEBUG`)

All new code below is inside `#if DEBUG` (like the Debug section in
`SettingsView`). Release builds contain none of it.

- **`TranscriptListView` / row:** new `onVoiceprintDebug: (Int) -> Void`
  property, passed like `onSpeaker`. The speaker-label `Button` gets
  `.contextMenu { Button("Voiceprint Debug…") { onVoiceprintDebug(speakerID) } }`.
  The row's `Equatable` conformance keeps ignoring closures.
- **`MeetingDetailViewModel`:**

  ```swift
  public struct VoiceprintDebugModel: Identifiable { public let id = UUID(); public var report: VoiceprintDebugReport }
  public var voiceprintDebug: VoiceprintDebugModel?
  func openVoiceprintDebug(speakerID: Int) async            // default kind = VoiceprintConfig.default.kind
  func reloadVoiceprintDebug(kind: VoiceprintKind) async
  ```

  Uses the transcript shown on screen (`selectedTranscript`, else the
  preferred one). Sets `voiceprintDebug` only after the report is loaded — the
  same race-free `.sheet(item:)` pattern as `summaryPromptModel`.
- **`MeetingDetailView`:** `.sheet(item: $viewModel.voiceprintDebug) {
  VoiceprintDebugView(…) }`.
- **`VoiceprintDebugView.swift`** (new), about 900 × 700:
  1. Header: "Speaker {id}", a segmented `Picker` (PLDA / Raw) that calls
     `reloadVoiceprintDebug`, a Done button.
  2. Summary line: space, voiceprints, meetings; or `errorMessage`; or "No
     voiceprint for this speaker".
  3. Level, then a `Table` of candidates (name, email, score, distance,
     meetings, confirmed, invited).
  4. A `Table` of nearest voiceprints (meeting, date, speaker, person or
     "unnamed", confirmed/inferred, distance, speaking time); rows outside `R`
     use secondary text color.
  5. The LLM block in a selectable monospaced `Text` in a `ScrollView`, with a
     Copy button (`NSPasteboard.general`).
  Uses `DesignSystem` tokens. No vector values are shown.
- `MeetingDetailUI` adds the `Intelligence` and `VoiceprintMatching`
  dependencies if not already present (for the report and `VoiceprintKind`
  — `VoiceprintKind` is in `DataStore`, which `MeetingDetailUI` already uses).

---

## 9. `voiceprint-cli`

Executable target in `Packages/BiscottiKit`, dependencies `DataStore`,
`VoiceprintMatching`, `Transcription` (product), `ArgumentParser`. Add
`swift-argument-parser` (`from: "1.3.0"`, as in `Transcription`) to
`BiscottiKit`'s package dependencies, and the product
`.executable(name: "voiceprint-cli", targets: ["voiceprint-cli"])`.

Files: `VoiceprintCLI.swift` (root `AsyncParsableCommand`), `BackfillCommand.swift`,
`MetricsCommand.swift`, `AppRunningGuard.swift`, `StoreLocation.swift`. Commands
stay thin; the logic is in tested library code.

Shared behavior:

- `--store PATH`: the directory that contains `Biscotti.store`. Default
  `~/Library/Application Support/Biscotti` (as in `BiscottiApp.buildCore`).
  Exit 1 with a clear message if `Biscotti.store` is missing (never create an
  empty store).
- `AppRunningGuard` (both commands): if `NSWorkspace.shared.runningApplications`
  contains bundle ID `net.scosman.biscotti`, print "Quit Biscotti first" to
  stderr and exit 2. Opening a `ModelContainer` can migrate the store; a CLI
  built from a newer schema must not do that while the app uses it.
- Progress and messages to **stderr**; results to **stdout**; `--json`
  switches stdout to JSON.

### 9.1 `backfill`

```
voiceprint-cli backfill [--store PATH] [--dry-run] [--limit N] [--meeting UUID] [--json]
```

1. Guard, open `DataStore(storage: .onDisk(store))`.
2. `spaces = [.raw: SpeakerEmbeddingSpace.current(.raw), .plda: …current(.plda)]`.
3. Candidates = `backfillCandidates()`, filtered by `--meeting`. For each,
   `neededKinds` = kinds where `!hasVoiceprints(transcriptID, kind, space)`.
   Skip with a reason when: either audio file is missing; `neededKinds` is
   empty; no stored segments. Then apply `--limit`.
4. `--dry-run`: print planned and skipped meetings (with needed kinds); no
   diarization; exit 0.
5. `SpeakerAnalyzer.ensureModelsDownloaded()`; for each candidate:
   - `analysis = analyze(micPath:systemPath:)`
   - `result = BackfillSpeakerMapper.map(fresh: analysis.spans, stored: candidate.segments)`
   - For each needed kind, take the set of that kind from `analysis.embeddingSets`;
     for each `(fresh, stored)` in `result.mapping` with a vector:
     `NewVoiceprint(speakerID: stored, vector:, speakingDuration:
     analysis.speakerSpeechDurations[fresh] ?? 0)`; then
     `addVoiceprints(items, kind:, space: set.space, to: transcriptID)`.
   - Per-meeting errors: stderr, count as failed, continue.
6. `unload()`. Summary: processed / skipped by reason / failed, voiceprints
   added per kind, speakers unmapped. Exit 1 if any meeting failed, else 0.

### 9.2 `metrics`

```
voiceprint-cli metrics [--store PATH] [--kind plda|raw|both] [--sweep] [--json]
```

Read only: calls no mutating method.

1. For each selected kind: `corpus = voiceprintCorpus(kind:, space:
   SpeakerEmbeddingSpace.current(kind), excludingMeetingID: nil)`;
   `VoiceprintEvaluator().evaluate(corpus)`.
2. stdout: `MetricsFormatter.text(results, includeSweep:)` or the JSON array.

---

## 10. Testing

Swift Testing for Biscotti code, XCTest in the SDK fork (its convention). No
model downloads except the gated AI tests.

### SDK fork (`SpeakerCentroidEmbeddingsTests`)

Listed in §2.1 step 5.

### Transcription (`TranscriptionTests`)

- `SpeakerDurations.compute`: sums per speaker; empty input.
- `EmbeddingSetBuilder` with a `DiarizationResult` built through its public
  generic init: both sets present; empty vectors dropped; a kind with no
  vectors omitted; correct `space` per kind.
- `SpeakerEmbeddingSpace.current`: raw `x/y`; PLDA `x/y+plda:z/w`; no
  `"unknown"` on macOS 15.
- `TranscriptResult` Codable round-trip with `embeddingSets` and
  `speakerSpeechDurations`.
- `TranscriptSanitizer` passes both new fields through.
- `AIModelTests` (gated): the multi-speaker fixture yields a raw set (256-dim)
  and a PLDA set (128-dim), and a duration for each diarized speaker.

### DataStore (`DataStoreTests`)

- `VectorCoding`: round-trip; wrong length → nil; NaN → nil.
- `addTranscript`: one `Voiceprint` per non-empty vector per kind, with the
  right kind, space, dimension, duration; non-finite vectors skipped.
- `voiceprintCorpus`: preferred transcript only; other kind and other space
  excluded; excluded meeting excluded; tags joined with `userSet`; dangling
  person → nil tag; `people` contains only referenced persons.
- `voiceprintQuery`: vectors and durations; nil space when none of that kind.
- Cascade: deleting a meeting deletes its voiceprints.
- `setParticipants(currentUser:)` → `calendarContext` marks exactly that person.
- `addVoiceprints` / `hasVoiceprints` per kind; `backfillCandidates` content
  and order.
- On-disk: write voiceprints, reopen the store, read identical vectors (pattern
  of `OnDiskMaterializationTests`).

### VoiceprintMatching (`VoiceprintMatchingTests`, new)

Synthetic vectors (for example 8-dim, built at known angles) so distances are
exact.

- `VectorMath`: normalization; zero / NaN / empty → nil; distance range and
  clamp.
- Matcher: nothing within R → none; one vote per meeting; best-K cap; confirmed
  outweighs inferred; short speech weighs less; invitee boost changes the
  winner; each level boundary (high, medium, low); both ambiguity triggers;
  ambiguous candidate cap; unnamed count only for untagged, deduplicated by
  meeting; dimension mismatch → none; deterministic tie-break; per-kind
  thresholds are used.
- `explain`: `match` equals `match()`'s result; `nearest` includes entries
  outside R, flagged; `allCandidates` is not truncated.
- `BackfillSpeakerMapper`: identity; renumbered speakers; one fresh speaker over
  two stored speakers; below threshold → unmapped; greedy conflict.
- `VoiceprintEvaluator`: **leakage test** — when a voiceprint's only close
  match is in its own meeting, it must not count as correct; sweep rates on a
  hand-computed corpus; EER choice; confused pairs; suspect tags; trials
  without history.
- `MetricsFormatter`: golden text for a small two-kind result.

### Intelligence (`IntelligenceTests`)

- `VoiceprintReport.render`: golden strings for every template row, three-way
  ambiguous, singular/plural, `(not invited)`, each invitee variant, assigned
  persons left out of the invitee part, `""` for empty history.
- `IntelligencePrompts`: block placement; omitted when empty; instruction
  paragraph present; current-user marker in the invitee list.
- `Intelligence` with `FakeLLMRunner`: the speaker turn's first user message
  contains the block from a seeded store; context-sizing content equals the
  sent content; a store error gives a prompt without the block and the run
  still completes.
- `voiceprintDebug` (tests build in debug): candidates and neighbors for a
  seeded store; a user-tagged speaker still gets candidates; a speaker with no
  voiceprint gives `hasVoiceprint == false`; the kind parameter switches the
  space.

### MeetingDetailUI (`MeetingDetailUITests`)

- `openVoiceprintDebug` sets `voiceprintDebug` with the report for the
  displayed transcript; `reloadVoiceprintDebug(kind:)` replaces the report.

### AppCore

- `persistSnapshot`: attendee with `isCurrentUser` → `currentUserPersonID` is
  that attendee's person; organizer case; none case.

### IntelligenceAITests (new, gated by `BISCOTTI_RUN_AI_TESTS=1`)

New `testTarget` in `BiscottiKit`, dependencies `Intelligence`, `DataStore`,
`LocalLLM`. An in-process `LLMRunning` (`LLMService` backend `.inProcess`) with
one shared connection and the ordered `atexit` teardown copied from
`LocalLLM/Tests/LocalLLMTests/IntegrationTests.swift` (without it, the ggml
Metal destructor aborts the test process). Model: `LLM_MODEL_PATH`, else the
app's default model file under `~/Library/Application Support/Biscotti/llms/`.
`.serialized`.

Each case builds the real first user message with `IntelligencePrompts` and a
handwritten `<voiceprint_matches>` block, runs with
`MeetingAnalyzer.speakerOptions` (`@testable import Intelligence`), and parses
with `SpeakerMappingParser`. Output varies, so each case runs 3 times and
passes when ≥2 runs are correct.

| Case | Expected |
|---|---|
| Speaker close to `Sam <sam@kiln.tech>` and `Samantha (no email)`; transcript has "Samantha" | Sam/Samantha; email `sam@kiln.tech` or blank, never another email (known limit: functional spec §7.4) |
| Close to `Dave (no email)` and `Amit (no email)`; transcript "thanks, Amit" | Amit |
| Speaker 1 high match `Steve <steve@kiln.tech>`; no name in transcript | Steve, `steve@kiln.tech` |

`Makefile` `test-ai` adds:
`BISCOTTI_RUN_AI_TESTS=1 swift test --package-path Packages/BiscottiKit --filter IntelligenceAITests`.

---

## 11. Error handling

| Where | Failure | Handling |
|---|---|---|
| Engine | Speaker has no centroid (either kind) | Normal: no vector, no voiceprint. |
| `addTranscript` | Non-finite vector | Skip that voiceprint, log; the transcript saves. |
| `addTranscript` | Save fails | Unchanged: the whole transcript save fails, as today. |
| Corpus read | Undecodable vector / wrong dimension | Skip the entry, debug log. |
| `VoiceprintEvidence.block` | Any thrown error | Log, return `""`; analysis continues without the block. |
| Debug report | Any thrown error | `errorMessage` set; window shows it. |
| CLI backfill | Per-meeting diarization or save error | stderr, count failed, continue; exit 1 at the end. |
| CLI | App running | Exit 2 with a message. |
| CLI | Store missing | Exit 1 with a message. |

---

## 12. Calibration pass

The last task of the project, run by the developer (it needs the real store and
the SpeakerKit models):

1. `voiceprint-cli backfill` (dry run first).
2. `voiceprint-cli metrics --kind both --sweep --json > calibration.json`.
3. Choose per-kind `acceptRadius`, `highDistance`, `mediumDistance`, and the
   default `kind`, from the sweep (EER radius as the starting point for `R`;
   `high` where accuracy at the high level is ≈100%).
4. Update `VoiceprintConfig` defaults, and record the numbers and the reasons in
   `specs/projects/speaker_embeddings/calibration.md`.

---

## 13. Documentation updates (in scope)

- `specs/research/argmax/README.md`: apply `sdk_findings.md` §7, and add the
  PLDA facts and the fork.
- `sdk_findings.md`: add a PLDA section (two vector types, `PldaProjector`,
  128-dim, why it fits cross-recording matching).
- `specs/architecture.md`: add `VoiceprintMatching` and `voiceprint-cli` to the
  topology and the dependency DAG.
- `specs/implementation_plan.md`: Project 11 status (voiceprint half built; no
  "me" setting, no microphone signal).
- `CLAUDE.md`: the SpeakerKit fork gotcha (§2.2 step 6).
- `DataStore+ReadModels.swift`: remove the "Not yet populated" comment.
- `Person.swift`: replace the "Reserved for P2" comment (voiceprints live on
  transcripts; there is no `isMe` flag).

---

## 14. Refinements to the functional spec

1. **Space keys** do not include the dimension; it is stored and checked per
   voiceprint (§3.2).
2. **`speakerEmbeddings` is removed** from `TranscriptResult` and replaced by
   `embeddingSets` (§3.1).
3. **Debug report** uses the displayed transcript version, not always the
   preferred one (§8).
