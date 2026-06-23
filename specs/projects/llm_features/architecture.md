---
status: complete
---

# Architecture: LLM Features

This is the **spine**. Two component docs carry the internal detail:
- `components/intelligence.md` — the new in-process `Intelligence` module (orchestration, prompts, parsing, model download, LLM abstraction).
- `components/ui_integration.md` — MeetingDetailUI (Summary tab, speaker names + sheet, status pill) and SettingsUI (AI Enhancements + download) changes.

The `LocalLLM` package and `BiscottiLLM.xpc` are **consumed, not modified**.

---

## 1. Module Placement & Dependencies

A new BiscottiKit target **`Intelligence`** — the direct analog of `TranscriptionService` : `Transcription`. It owns all app-specific LLM scenario logic and is the *only* app-side place that knows how to drive the LLM for a Biscotti feature.

```
TranscriptionService  →  Transcription (pkg, links WhisperKit/SpeakerKit)
Intelligence          →  LocalLLM      (pkg, links llama.cpp; we use the .hosted XPC backend)
```

**Package wiring (`Packages/BiscottiKit/Package.swift`):**
- Add dependency `.package(name: "LocalLLM", path: "../LocalLLM")`.
- New `.target(name: "Intelligence", dependencies: ["DataStore", .product(name: "LocalLLM", package: "LocalLLM")])` + product + `IntelligenceTests` target.
- `AppCore` gains dependency `"Intelligence"`.
- `MeetingDetailUI` and `SettingsUI` gain dependency `"Intelligence"` (to read its observable status/download enums, exactly as they already import `TranscriptionService` for `JobStatus`).

**Known tradeoff — llama links into the app process.** `LocalLLM` is a single library target that links the llama.cpp xcframework; there is no client-only product. Importing it into `Intelligence` (hence `AppCore`, hence the app) embeds `llama.framework` in the app binary and dyld-loads it at launch. This is **functionally harmless** — the app always uses `.hosted(serviceName:)`, so inference runs in `BiscottiLLM.xpc` and crash/Metal-memory isolation is fully preserved (the XPC `_exit(0)` reclamation is unchanged). It is the same arrangement the `ManualTestApp` already ships. Cost: a larger app binary + a dylib load at launch (no GPU init, since the in-process engine is never created). **We accept this and do not modify `LocalLLM`.** (Optional future cleanup, out of scope: split `LocalLLM` into `LocalLLMClient`/`LocalLLMEngine` products so the app links only the client.)

**App target / XcodeGen:** because the app process now references `LocalLLM`, the app target must **embed `llama.framework`** (the XPC target already does). This is a one-time integration step (Phase 1) — verified by launching the app and opening a hosted connection.

---

## 2. Data Model Changes

SwiftData. **All additive, default-valued** → SwiftData lightweight handling; **no new `VersionedSchema`/migration stage** required (the store already adds defaulted properties to V1 without stages; the migration plan is currently an unwired TODO and stays so). New model types added to `DataStoreSchemaV1.models` only if we introduce a new `@Model` — we do **not** (everything hangs off existing models).

| Model | Added |
|---|---|
| `Meeting` | `summary: String = ""`; `editedSummary: Bool = false` |
| `TranscriptRecord` | `speakerAssignmentsData: Data = Data()` (private) + `@Transient var speakerAssignments: [Int: UUID]` (JSON via `JSONEncoder`/`Decoder`, mirroring `vocabularyUsed`) |
| `AppSettings` | `summarizeTranscripts: Bool = true`; `guessSpeakerNames: Bool = true` |

- **`Meeting.summary`** holds markdown; `editedSummary` mirrors the existing `editedTitle` semantics (set true on human edit; gates auto/overwrite).
- **`TranscriptRecord.speakerAssignments`** maps diarization **speaker ID → `Person.id`**. Empty = no assignments. Lives on the transcript so it resets to empty on re-transcription. (`[Int: UUID]` round-trips through Swift's `JSONEncoder`/`JSONDecoder` as a flat array — acceptable; the field is internal.)

### Read-model / DTO changes (`DataStore+ReadModels.swift`)
- **`SegmentData`**: add `speakerID: Int?` (needed to map a segment to a name/color by ID).
- **`TranscriptData`**: add `speakerAssignments: [Int: PersonData]` — the transcript's map **resolved** to people (for both name rendering and the editing sheet). Convenience `func speakerName(forID:) -> String?`.
- **`MeetingDetailData`**: add `summary: String`, `editedSummary: Bool`. (Its `preferredTranscript: TranscriptData?` already carries the resolved assignments; version-switching loads another `TranscriptData` via `transcript(id:)` which also carries them.)
- `AppSettingsData`: add `summarizeTranscripts`, `guessSpeakerNames` (mirror, threaded through `settings()` / `updateSettings`).

---

## 3. DataStore API Additions

All on the `DataStore` actor (signatures; bodies follow existing patterns — `setNotes`/`setTitle`/`findOrCreatePerson` are the templates):

```swift
// Summary
func applyGeneratedSummary(_ markdown: String, for meetingID: UUID) throws   // sets summary, editedSummary = false
func setSummary(_ markdown: String, for meetingID: UUID) throws               // user edit: sets summary, editedSummary = true

// Speaker assignments (per transcript)
func setSpeakerAssignments(_ assignments: [Int: UUID], for transcriptID: UUID) throws        // replace whole map
func setSpeakerAssignment(speakerID: Int, personID: UUID?, for transcriptID: UUID) throws     // set one; nil clears

// People (production autocomplete source; replaces the test-only fetchAllPersons)
func allPersonData() throws -> [PersonData]
```

- `meetingDetail(id:)` and `transcript(id:)` are extended to populate `summary`/`editedSummary` and resolve `speakerAssignments: [Int: PersonData]` (fetch the `Person`s referenced by the transcript's map; drop dangling IDs defensively).
- `findOrCreatePerson(name:email:)` (existing) is reused by both the LLM resolution path and the manual "add person" path.

---

## 4. Components & Public Interfaces

### 4.1 `Intelligence` (new) — `@MainActor @Observable`
Parallels `TranscriptionService`: holds observable per-meeting status the UI watches, plus the model-download state. Depends on injected abstractions (not `LLMService` directly) so it unit-tests without a model.

```swift
@MainActor @Observable
public final class Intelligence {
    public package(set) var jobs: [UUID: EnhancementStatus] = [:]      // status pill
    public package(set) var streamingSummary: [UUID: String] = [:]     // live partial markdown
    public package(set) var download: ModelDownloadState = .unknown    // Settings download row

    public init(store: DataStore, llm: LLMRunning, models: ModelProviding, settings: @escaping () async -> AISettings)

    /// Post-transcription auto-run. Reads settings + model presence; runs speaker-ID
    /// then summary in ONE llm session; honors the edited-summary guard. No-op if
    /// no model, both toggles off, or no transcript.
    public func runAutoEnhancements(meetingID: UUID) async

    /// Manual "Generate"/"Regenerate Summary" from the Summary tab — summary only,
    /// from the given transcript version. `force` bypasses no edited check (caller
    /// already confirmed). Streams into `streamingSummary`.
    public func generateSummary(meetingID: UUID, transcriptID: UUID, force: Bool) async

    public var isModelDownloaded: Bool { get }
    public func refreshModelState()             // recompute `download` from disk presence
    public func downloadModel() async           // drives `download` through downloading→downloaded/failed
}

public enum EnhancementStatus: Sendable, Equatable {
    case identifyingSpeakers
    case summarizing
    case completed
    case failed(message: String)
}

public enum ModelDownloadState: Sendable, Equatable {
    case unknown
    case notDownloaded
    case downloading(fraction: Double?)   // nil when total unknown
    case downloaded
    case failed(message: String)
}

public struct AISettings: Sendable { public var summarize: Bool; public var guessSpeakers: Bool }
```

Injected abstractions (real impls wrap `LocalLLM`; fakes in tests):
```swift
public protocol LLMRunning: Sendable {                 // one loaded-model session, N calls
    func withSession<T: Sendable>(_ body: @Sendable (LLMSession) async throws -> T) async throws -> T
}
public protocol LLMSession: Sendable {
    func generate(system: String, user: String, options: GenerationOptions) async throws -> String
    func generateStreaming(system: String, user: String, options: GenerationOptions) -> AsyncThrowingStream<StreamEvent, Error>
}
public protocol ModelProviding: Sendable {
    var modelURL: URL { get }
    func isDownloaded() -> Bool
    func download(progress: @Sendable @escaping (Int64, Int64?) -> Void) async throws
}
```
Internal collaborators (detailed in `components/intelligence.md`): `IntelligencePrompts` (Swift-constant catalog), `TranscriptFormatter` (segments + name map → plain text turns), `SpeakerMappingParser` (`idx | name | email` line parser), `SpeakerIdentifier`, `Summarizer`, `ModelManager`.

### 4.2 `AppCore` (existing) — wiring
- Owns an `intelligence: Intelligence`, built in the live composition root with the real `LocalLLM`-backed `LLMRunning`/`ModelProviding` and a settings closure reading `store.settings()`.
- `stopRecording()`: inside the existing fire-and-forget Task, **after** `await transcription.transcribe(meetingID:)`, add `await intelligence.runAutoEnhancements(meetingID:)`. (STT engine is already shut down before `transcribe` returns → memory-safe.)

### 4.3 `MeetingDetailUI` (existing) — see `components/ui_integration.md`
- `Tab.summary` (declared first). Summary tab: `MarkdownEditor` + states (streaming/empty/error). Observes `core.intelligence.jobs[meetingID]` and `streamingSummary[meetingID]`.
- `reTranscribe()`: after the existing `await … reTranscribe()` + `load()`, trigger `core.intelligence.runAutoEnhancements(meetingID:)` (observed).
- Overflow menu: "Regenerate Summary" (+ edited-summary confirm). Generate path → `intelligence.generateSummary`.
- Transcript: `SpeakerLink` URL on speaker spans → `SpeakerMappingSheet`. Name replacement from `TranscriptData.speakerAssignments`.
- Tab-bar status pill bound to `intelligence.jobs[meetingID]`.

### 4.4 `SettingsUI` (existing) — see `components/ui_integration.md`
- "AI Enhancements" `Section`: two toggles bound to `AppSettings` via `SettingsViewModel`; conditional download row bound to `core.intelligence.download` + `downloadModel()`.

---

## 5. End-to-End Flows

### 5.1 Auto-run (after recording or re-transcribe)
1. Transcription completes & persists; STT engine shut down (existing).
2. `intelligence.runAutoEnhancements(meetingID:)`:
   - Load `AISettings`; if no model (`isDownloaded == false`) or both toggles off → return.
   - Load preferred `TranscriptData` (+ `MeetingDetailData` for `editedSummary`); if no transcript → return.
   - `jobs[meetingID] = .identifyingSpeakers` (if guessing) ; open **one** `llm.withSession`:
     - **Speaker-ID** (if `guessSpeakers`): build user msg (invitees from `store.calendarContext` + transcript turns) → `session.generate(...)` → `SpeakerMappingParser` → `findOrCreatePerson` per line → `store.setSpeakerAssignments(...)`. Reload to expose resolved names.
     - **Summary** (if `summarize` **and** `!editedSummary`): `jobs = .summarizing`; build user msg using the **resolved speaker names**; `session.generateStreaming(...)` → accumulate into `streamingSummary[meetingID]` → on `.done`, `store.applyGeneratedSummary(text, for:)`.
   - `jobs[meetingID] = .completed` (then cleared); failures → `.failed`.
3. Open detail view observes `jobs`/`streamingSummary`, reloads on `.completed`, renders names + summary.

### 5.2 Manual Generate / Regenerate Summary
- Empty-state button or "…" menu → if `editedSummary` and not yet confirmed, show confirm dialog → on proceed, `intelligence.generateSummary(meetingID:transcriptID: activeVersionID, force: true)`; streams into the Summary tab; persists with `editedSummary = false`.

### 5.3 Manual speaker rename (no model needed)
- Click speaker → `SpeakerMappingSheet` → pick existing person (`store.allPersonData()` / invitees) or add-by-name (`findOrCreatePerson(name:, email: nil)`) or Unassigned → `store.setSpeakerAssignment(speakerID:personID:for:)` → transcript re-renders.

### 5.4 Model download (Settings)
- `intelligence.downloadModel()` drives `download`: `.downloading(fraction)` (from `ModelProviding.download(progress:)`) → `.downloaded` (toggles enable) or `.failed` (Retry). Pure URLSession; no XPC.

---

## 6. Error Handling

- **AI is never a gate.** All failures are non-fatal and quiet.
- `EnhancementStatus.failed(message)` drives a dismissible Summary-tab `Banner` + Retry; speaker-ID failure is silent (labels stay "Speaker N").
- Parser failures are line-local (skip bad lines); a fully unparseable response → empty map (no error).
- Context overflow / inference errors (incl. very long ~3h transcripts) surface as the summary error; no crash.
- `LLMServiceError.serviceInterrupted` (XPC crash) → `.failed`; the connection is discarded; next run reconnects.
- Download errors → `ModelDownloadState.failed` + Retry.
- Cancellation: detail view disappearance / app quit cancels the in-flight task; the `withSession` closes the connection; no partial summary persisted unless a generation completed.
- Logging via the repo's existing logging approach; no transcript/PII logged.

---

## 7. Concurrency

- `Intelligence` is `@MainActor`; LLM/model calls are `async` (cross to XPC / URLSession off-main).
- **Single AI run in flight** (guard like `TranscriptionService.inFlightMeetingID`); `LLMConnection` also serializes. Manual Generate/Regenerate is disabled in the UI while a run is active for that meeting.
- Auto-run starts only after transcription fully completes (transcription is single-in-flight), so STT and LLM never co-reside.

---

## 8. Testing Strategy

Swift Testing, matching repo norms (logic unit-tested; views via view-model tests). New/updated suites:

- **IntelligenceTests** (fakes for `LLMRunning`/`ModelProviding`/settings; no real model):
  - Prompt building: system/user content; **summary user message contains resolved names** and runs **after** speaker-ID persisted (ordering).
  - `SpeakerMappingParser`: well-formed lines; code-fenced; blank email; extra prose; malformed lines skipped; garbage → empty.
  - Orchestration: gating (both/one/neither toggle; no model); edited-summary guard skips summary; **exactly one `withSession`** for a both-on run; streaming accumulation; persistence calls (`setSpeakerAssignments`, `applyGeneratedSummary`); failure → `.failed`; cancellation.
  - `ModelManager`/download state machine (fake progress → downloaded; error → failed→retry).
- **DataStoreTests**: `applyGeneratedSummary` (editedSummary=false) vs `setSummary` (true); `setSpeakerAssignments`/`setSpeakerAssignment` (set + clear + dangling-ID drop); `allPersonData`; read models carry `summary`/`editedSummary`/`speakerID`/resolved `speakerAssignments`; `[Int:UUID]` round-trip.
- **MeetingDetailUITests**: Summary tab state machine (content/streaming/empty×{no-model,off,ready}/error/no-transcript); regenerate confirm gating on `editedSummary`; name replacement from assignments; per-ID color stability; `SpeakerMappingSheet` option assembly (invitees→people→add→unassign) + apply/clear; status-pill visibility from `jobs`.
- **SettingsUITests**: toggle persistence + revert-on-failure; no-model disabled/off; download-row state machine; flip no-model→model when download completes.
- **AppCoreTests**: `stopRecording` triggers `runAutoEnhancements` after transcription (fake intelligence); does not run when settings off / no model.
- **Transcript rendering**: `TranscriptContent` renders names when assignments present, "Speaker N" otherwise.

---

## 9. Decisions & Open Points (for review)

1. **`Intelligence` as a BiscottiKit module** (not a separate `Packages/Intelligence`): avoids an SPM package cycle (it needs `DataStore`, and `AppCore` needs it) and mirrors `TranscriptionService`. ✔ recommended.
2. **Accept llama linking into the app** (don't split `LocalLLM`). ✔ recommended — see §1.
3. **Additive schema, no explicit V2.** ✔ recommended (consistent with current store).
4. **LLM access behind `LLMRunning`/`LLMSession` protocols** (real wraps `LLMService.withConnection`; fakes for tests) — the key testability seam.
5. **One observable service** (`Intelligence`) owns enhancement status, streaming partial, and download state; UI observes via `AppCore`, mirroring `TranscriptionService`.
