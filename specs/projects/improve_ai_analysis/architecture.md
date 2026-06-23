---
status: complete
---

# Architecture: Improve AI Analysis

This is a cross-cutting refactor of existing components, not a set of new components, so
everything lives in this single doc (no `/components` designs). It is organized
bottom-up: LocalLLM (message format → KV reuse), then the BiscottiKit app layers
(DataStore, Intelligence, UI), then the manual-test app, then testing.

File references use real paths/symbols from the current tree.

---

## 0. Layer map & what changes

```
LocalLLM (Packages/LocalLLM)                         ← Phases 1–2
  LLMMessage (new)              chat message value type
  GemmaChatTemplate            single-turn → multi-turn render
  LLMEngine                    messages API + KV-cache prefix reuse
  InferenceEngine / ServiceBackend / InProcessBackend / XPCBackend   messages signatures
  LLMConnection                messages API
  LLM{Generate,CountTokens}Request DTOs   messages payload
  LLMServiceProtocol           (Data-based methods unchanged in shape)
  GenerationResult             + cachedPromptTokenCount
XPCServices/BiscottiLLM/main.swift          decode new DTOs, call messages API   ← Phase 1
BiscottiKit/Intelligence                                                          ← Phase 3
  LLMSession / LiveLLMSession  messages API
  IntelligencePrompts          analysis system + turn builders
  MeetingAnalyzer (new)        the multi-turn conversation orchestrator
  Intelligence                 auto-run + manual runAnalysis use MeetingAnalyzer
  ContextSizing                conversation-aware sizing
  (SpeakerIdentifier, Summarizer removed; parse/persist folded into MeetingAnalyzer)
BiscottiKit/DataStore                                                             ← Phase 3/4
  + humanSetSpeakerMappings(for:)            human-set provenance accessor
  AppSettings / AppSettingsData              two AI bools → one aiAnalysisEnabled   (Phase 4)
BiscottiKit UI (SettingsUI, MeetingDetailUI)                                       ← Phase 4
ManualTestApp + ManualTestKit (LocalLLMScript, WiredScripts)                       ← Phases 1–2
```

---

## 1. LocalLLM — message format (Phase 1)

### 1.1 `LLMMessage` (new value type)

New file `Packages/LocalLLM/Sources/LocalLLM/LLMMessage.swift`:

```swift
public struct LLMMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case system, user, assistant }
    public let role: Role
    public let content: String
    public init(role: Role, content: String) { self.role = role; self.content = content }

    public static func system(_ c: String) -> LLMMessage { .init(role: .system, content: c) }
    public static func user(_ c: String) -> LLMMessage { .init(role: .user, content: c) }
    public static func assistant(_ c: String) -> LLMMessage { .init(role: .assistant, content: c) }
}
```

This is the single message type used at every layer (LocalLLM and BiscottiKit both import
`LocalLLM`, so it is not redefined in BiscottiKit).

**Ordering contract** (callers obey; the service does not validate): optional leading
`system`, then alternating `user`/`assistant`, ending on a `user` turn for a generate call.

### 1.2 Chat template: single-turn → multi-turn

`ChatTemplate.swift`. Change the protocol and the Gemma implementation to take a message
list. Keep all existing turn markers and the thinking/prefill behavior — only generalize
the loop.

```swift
public protocol ChatTemplating: Sendable {
    func render(messages: [LLMMessage], addGenerationPrompt: Bool) -> String
}
```

`GemmaChatTemplate.render(messages:addGenerationPrompt:)`:

1. For each message (trimming content, matching the current `| trim`):
   - `.system`: `"<|turn>system\n" + (thinkingEnabled ? "<|think|>\n" : "") + content + "<turn|>\n"`.
   - `.user`: `"<|turn>user\n" + content + "<turn|>\n"`.
   - `.assistant`: `"<|turn>model\n" + content + "<turn|>\n"`  (completed turn — **no**
     empty-thought prefill; see §2.4 for why this is correct and still reuses the transcript).
2. **Thinking-with-no-system edge** (preserve today's behavior): if `thinkingEnabled` and the
   list contains **no** `.system` message, emit the bare directive turn
   `"<|turn>system\n<|think|><turn|>\n"` once, before the first message.
3. If `addGenerationPrompt`: append `"<|turn>model\n"` + (`thinkingEnabled ? "" :
   emptyThoughtPrefill`).

**Parity requirement (tested):** `render([.system(s), .user(u)], addGenerationPrompt: true)`
must be byte-identical to the previous `render(system: s, user: u, addGenerationPrompt: true)`,
and `render([.user(u)], …)` identical to the previous `render(system: nil, user: u, …)`. The
existing template tests pin these exact strings; they are kept and the call sites updated.

### 1.3 Request DTOs

`LLMRequestDTOs.swift`:

```swift
public struct LLMGenerateRequest: Codable, Sendable, Equatable {
    public let messages: [LLMMessage]
    public let options: GenerationOptions
}

public struct LLMCountTokensRequest: Codable, Sendable, Equatable {
    public let messages: [LLMMessage]
    public let applyChatTemplate: Bool   // default true
    public let thinking: ThinkingMode    // default .off
}
```

`LLMLoadRequest` is unchanged. The `@objc LLMServiceProtocol` methods are **unchanged in
shape** — they still carry JSON-encoded `Data` (`generate(requestData:)`,
`generateStreaming(requestData:)`, `countTokens(requestData:)`); only the encoded DTO
contents change. `LLMEventReporting` (reverse streaming proxy) is unchanged.

### 1.4 Engine / backend / connection signatures

Replace the `(system:user:)` / `(prompt:system:)` pairs with `messages:` throughout:

```swift
// InferenceEngine (public protocol) + LLMEngine
func countTokens(messages: [LLMMessage], applyChatTemplate: Bool, thinking: ThinkingMode) async throws -> Int
func generate(messages: [LLMMessage], options: GenerationOptions) async throws -> GenerationResult
func generateStreaming(messages: [LLMMessage], options: GenerationOptions) async -> AsyncThrowingStream<StreamEvent, Error>

// ServiceBackend (adds id, as today)
func countTokens(messages: [LLMMessage], applyChatTemplate: Bool, thinking: ThinkingMode) async throws -> Int
func generate(id: UInt64, messages: [LLMMessage], options: GenerationOptions) async throws -> GenerationResult
func generateStreaming(id: UInt64, messages: [LLMMessage], options: GenerationOptions) -> AsyncThrowingStream<StreamEvent, Error>

// LLMConnection (public)
func countTokens(messages: [LLMMessage], applyChatTemplate: Bool = true, thinking: ThinkingMode = .off) async throws -> Int
func generate(messages: [LLMMessage], options: GenerationOptions = .default) async throws -> GenerationResult
func generateStreaming(messages: [LLMMessage], options: GenerationOptions = .default) -> AsyncThrowingStream<StreamEvent, Error>
```

`InProcessBackend` forwards to the engine; `XPCBackend` JSON-encodes the new DTOs;
`MockEngine` (tests) adopts the messages signatures. The serial semaphore, `id` allocation,
state machine, streaming relay, and cancellation paths are all unchanged — the only edit is
the parameter shape.

`reconfigure(contextSize:)`, `countTokens` plumbing, and the `Int32` wire narrowing are
untouched.

### 1.5 XPC service host

`XPCServices/BiscottiLLM/main.swift`: `generate` / `generateStreaming` / `countTokens`
decode the new DTOs and call `conn.generate(messages:options:)` etc. No structural change.

---

## 2. LocalLLM — KV-cache prefix reuse (Phase 2)

All in `LLMEngine` (the actor owning the llama.cpp context + KV cache). The
`LLMConnection` semaphore guarantees one in-flight generation per connection, so the
reuse state below is only ever touched by one call at a time.

### 2.1 New engine state

```swift
private var cachedTokens: [llama_token] = []   // the exact tokens currently resident in KV (seq 0)
```

Reset to `[]` whenever the context is (re)created or freed: in `createContext(config:)`,
in `unload()`, and on any generation error/cancellation (see §2.5). After a successful
generation it reflects what is physically in the KV cache.

### 2.2 The reuse algorithm (replaces the unconditional `llama_memory_clear` in `runGeneration`)

`runGeneration(messages:options:onToken:)`:

```
render messages → promptString → newTokens = tokenize(promptString)   // add_special=true (BOS), parse_special=true
let memory = llama_get_memory(ctx)

// 1. longest common token prefix with what's already in KV
var L = commonPrefixLength(cachedTokens, newTokens)

// 2. must leave ≥1 token to evaluate (need fresh logits to sample)
if L == newTokens.count { L = newTokens.count - 1 }
if L < 0 { L = 0 }

// 3. drop the divergent KV tail (no-op when cache empty / L == cachedTokens.count)
if L < cachedTokens.count { llama_memory_seq_rm(memory, 0, Int32(L), -1) }

// 4. context-overflow guard uses the FULL prompt (whole conversation must fit in KV)
if newTokens.count + 1 > config.contextSize { throw .contextOverflow(...) }

// 5. prefill ONLY the suffix; positions continue from L
let suffix = Array(newTokens[L...])
try promptEval(tokens: suffix, ctx: ctx)        // see §2.3 for the position note

// 6. sampling decode loop — UNCHANGED from today; collect generated content tokens
//    (each generated token is llama_decode'd into KV; the final stop token is not)

// 7. update reuse state: KV now holds all of newTokens + the decoded generated tokens
cachedTokens = newTokens + generatedContentTokens
```

`commonPrefixLength(a, b)`: pure helper, returns the first index where `a`/`b` differ (or
`min(a.count, b.count)`). Unit-tested.

`cachedPromptTokenCount = L` is threaded into `GenerationResult` (§2.6). `promptTokenCount`
stays the **full** prompt length (`newTokens.count`); `promptEvalDuration` now measures only
the suffix prefill.

### 2.3 Position continuation (the one on-hardware risk)

`promptEval` uses `llama_batch_get_one`, which (per the existing comment in `promptEval`)
"auto-assigns KV-cache positions from the context's running counter." After
`llama_memory_seq_rm(memory, 0, L, -1)` the cache for seq 0 holds positions `[0, L)`, so the
next `llama_decode` of the suffix must resume at position `L`.

- **Primary mechanism:** rely on `seq_rm` + `llama_batch_get_one` resuming at `L` (this is
  the standard llama.cpp prompt-reuse / context-shift pattern, and the existing multi-chunk
  prefill already depends on the running-counter behavior).
- **Fallback (only if hardware shows drift):** build an explicit `llama_batch` for the
  suffix with positions `L, L+1, …`. This is the single thing to confirm on hardware; the
  manual-test KV-reuse step is designed to catch it — drift produces garbled second-turn
  output and/or a wrong `cachedPromptTokenCount`.

### 2.4 Why this reuses the transcript (the actual win)

Within one analysis session (one connection), turn 1 prompt =
`system + user1(+transcript) + "<|turn>model\n" + emptyThoughtPrefill`, and after generation
the KV holds that plus the generated speaker tokens. Turn 2 re-renders the full conversation;
its rendered prefix is identical up to and including `"<|turn>model\n"` (the assistant turn's
opener), then diverges (turn-1 KV has the thought prefill; turn-2 render has the assistant
content). So `L ≈ tokens(system + user1)` — **the entire transcript prefix is reused**. The
re-decoded suffix is only the small assistant-1 text + the short `user2` summary task + the
new generation prefix. We deliberately do **not** try to make completed assistant turns
re-tokenize bit-for-bit (that fragility buys only a few hundred tokens); the diff guarantees
correctness regardless and the transcript is always before the divergence.

### 2.5 Error / cancellation consistency

If `runGeneration` throws or is cancelled after partial prefill/decode, the KV cache is in an
indeterminate state. On every error/cancel exit, clear it (`llama_memory_clear(memory, true)`)
and set `cachedTokens = []`. The next call then starts cold (correct, just no reuse). This is
the simple, safe policy; reuse is a performance optimization, never a correctness dependency.

### 2.6 `GenerationResult` addition

```swift
/// Prompt tokens served from the KV cache (reused prefix) this call. 0 when cold.
public let cachedPromptTokenCount: Int
```

Added to the initializer and `Codable`. All construction sites set it (`runGeneration`
passes `L`; tests/mock pass `0`).

### 2.7 Timing logging (`#if DEBUG`) — confirm the speed boost

`LLMEngine.runGeneration` already logs prefill and generation as two separate `Logger.info`
lines (`LLMEngine.swift:411` "Prefill complete…" and `:495` "Generation complete…"). Those
stay, but they don't show the cache split that proves reuse. Add a `#if DEBUG` block at the
end of `runGeneration` emitting the per-call breakdown so we can verify the expected boost:

```
#if DEBUG
// e.g. "KV reuse: cached=8123 fresh=214 / prompt=8337 tokens | prefill(fresh)=92ms (2.3 t/s)
//       | generate=1840ms 256 tokens (139 t/s)"
Self.log.debug("""
KV reuse: cached=\(L) fresh=\(newTokens.count - L) / prompt=\(newTokens.count) tokens \
| prefill(fresh)=\(formatMs(prefillSeconds))ms \
| generate=\(formatMs(genSeconds))ms \(generatedCount) tokens (\(genTPS) t/s)
""")
#endif
```

This keeps the two metrics the user asked for — **decoding/prefill** (now only the fresh
suffix) and **fresh generation** — as distinct numbers, plus the `cached` count. Across the
two analysis turns, turn 2 should show `cached ≈ tokens(system+transcript)` and a prefill
time near zero, which is exactly the win. (Already-`#if DEBUG`-only so it never ships.)

### 2.8 Scope reminder

Reuse spans turns **within one connection**. The service still `_exit(0)`s when the last
connection closes (unchanged), so memory is reclaimed between meetings. A new meeting =
new connection = cold cache (different transcript shares no useful prefix). No cross-session
warming.

---

## 3. BiscottiKit — DataStore (Phase 3 + 4)

### 3.1 Human-set speaker provenance accessor (Phase 3)

The read model `TranscriptData.speakerAssignments` is `[Int: PersonData]` and drops the
`userSet` flag, but the analysis needs (a) the human-set mappings to put in the prompt and
(b) the set of human-set speaker IDs to gate the speaker turn. Add to
`DataStore+LLMFeatures.swift`:

```swift
/// Returns only the human-set (`userSet == true`) speaker assignments, resolved to people.
/// Dangling person IDs are dropped (same policy as mapTranscript).
func humanSetSpeakerMappings(for transcriptID: UUID) throws -> [Int: PersonData]
```

Implementation reads `record.speakerAssignments` (the `[Int: SpeakerAssignmentEntry]`),
keeps `userSet == true`, resolves each `personID` via the existing person fetch.

The existing write-side guarantee is unchanged and authoritative:
`setSpeakerAssignments(_:for:)` already skips any `current[speakerID]?.userSet == true`
(`DataStore+LLMFeatures.swift:46`), so AI results can never overwrite human assignments —
even if the model returns a line for one.

### 3.2 Settings field consolidation (Phase 4)

Replace the two bools with one in **all four** mirror sites:

- `AppSettings` (`Models/AppSettings.swift`): remove `summarizeTranscripts` /
  `guessSpeakerNames`; add `public var aiAnalysisEnabled: Bool = true`. Update `init`.
- `AppSettingsData` (`DataStore+ReadModels.swift`): same swap; update `init`.
- `DataStore.settings()` and `updateSettings(...)`: map the single field.

SwiftData relies on automatic lightweight migration (add property with default, drop two
properties). Pre-release: if a dev store fails to migrate, wiping it is acceptable (no
shipped users). No `@Model` is added, so the container schema list is unchanged.

---

## 4. BiscottiKit — Intelligence (Phase 3)

### 4.1 `LLMSession` / `LiveLLMSession` → messages

`LLMRunning.swift`:

```swift
public protocol LLMSession: Sendable {
    func countTokens(messages: [LLMMessage]) async throws -> Int   // applyChatTemplate=true, thinking=.off
    func reconfigure(contextSize: Int) async throws
    func generate(messages: [LLMMessage], options: GenerationOptions) async throws -> String
    func generateStreaming(messages: [LLMMessage], options: GenerationOptions) async -> AsyncThrowingStream<StreamEvent, Error>
}
```

`LiveLLMSession` (`LiveLLMRunning.swift`) forwards to `connection.generate(messages:options:)`,
`generateStreaming(messages:options:)`, `countTokens(messages:)`. `withSession` is unchanged.

### 4.2 `AISettings` → single flag

`EnhancementStatus.swift`:

```swift
public struct AISettings: Sendable { public var enabled: Bool }
```

`AppCore+Live.swift` settings closure:
- **Phase 3 (interim):** `AISettings(enabled: (s?.summarizeTranscripts ?? true) || (s?.guessSpeakerNames ?? true))`
  — keeps Intelligence functional before the field swap.
- **Phase 4:** `AISettings(enabled: s?.aiAnalysisEnabled ?? true)`.

`EnhancementStatus` keeps its cases (`preparing`, `identifyingSpeakers`, `summarizing`,
`completed`, `failed`) — they still drive the two pipeline stages.

### 4.3 Prompt catalog (`IntelligencePrompts.swift`)

Pure functions (all unit-tested per the functional spec). Replaces the old
`summarySystem/summaryUser/speakerSystem/speakerUser`.

```swift
static let analysisSystem: String
// "You will be given a meeting transcript and asked several questions about it across
//  multiple turns (for example, identifying the speakers, then writing a summary). Answer
//  each turn precisely, following exactly the format requested in that turn."

static func meetingDetailsBlock(_ detail: MeetingDetailData) -> String        // <meeting_details>…</meeting_details>; "" if nothing
static func userSpeakerMappingBlock(_ human: [Int: PersonData]) -> String     // <user_speaker_person_mapping>…; "" if empty
static let speakerTaskInstructions: String                                    // format + "respect mappings, only assign unassigned"
static let summaryTaskInstructions: String                                    // markdown + ## Action Items, no preamble, may use identified names

// First user turn when the speaker turn WILL run (transcript with Speaker-N labels):
static func analysisFirstUser(detail: MeetingDetailData, human: [Int: PersonData], transcriptSpeakerLabeled: String) -> String
// = meetingDetailsBlock + userSpeakerMappingBlock(human) + "<transcript>\n…\n</transcript>" + speakerTaskInstructions

// First user turn when ONLY the summary runs (transcript with resolved human names):
static func summaryOnlyFirstUser(detail: MeetingDetailData, transcriptNamed: String) -> String
// = meetingDetailsBlock + "<transcript>\n…\n</transcript>" + summaryTaskInstructions

// Follow-up user turn (summary task only; transcript already in context):
static let summaryFollowUpUser: String   // = summaryTaskInstructions
```

`meetingDetailsBlock` field rules (omit a line/section when the value is absent/empty; omit
the whole block if all are empty):
- `Title:` ← `detail.title`
- `Date:` ← `detail.date` (+ `–detail.endDate` when present), via a fixed formatter
- `Location:` ← `detail.calendar?.location`
- `Conference:` ← `detail.calendar?.conferencePlatform`
- `Invitees:` ← organizer first then attendees (deduped), `- Name <email>` (email omitted if
  blank) — same extraction as today's `extractInvitees`
- `Description:` ← `detail.calendar?.eventNotes` (whole "Description:" sub-block omitted if empty)

`userSpeakerMappingBlock`: one line per human-set entry,
`"<index> | <name> | <email-or-blank>"`; returns `""` when the map is empty (caller omits the
block).

### 4.4 `MeetingAnalyzer` (new) — the conversation orchestrator

New file `Packages/BiscottiKit/Sources/Intelligence/MeetingAnalyzer.swift`. Replaces
`SpeakerIdentifier` and `Summarizer` (both removed); `SpeakerMappingParser` and
`TranscriptFormatter` are reused unchanged.

```swift
enum MeetingAnalyzer {
    static let speakerOptions = GenerationOptions(maxTokens: 512, temperature: 0.2, thinking: .off)
    static let summaryOptions = GenerationOptions(maxTokens: 2048, temperature: 0.6, thinking: .off)

    struct Context {
        let meetingID: UUID
        let detail: MeetingDetailData
        let transcript: TranscriptData
        let human: [Int: PersonData]          // human-set mappings (from DataStore)
        let doSpeakers: Bool
        let doSummary: Bool
        let store: DataStore
        let onStage: @MainActor (EnhancementStatus) -> Void   // .identifyingSpeakers / .summarizing
        let onPartialSummary: @MainActor (String) -> Void
    }

    @MainActor static func run(_ session: any LLMSession, _ ctx: Context) async throws
}
```

`run` flow:

```
messages = [ .system(analysisSystem) ]

if ctx.doSpeakers {
    let t = TranscriptFormatter.plain(ctx.transcript, names: [:])               // Speaker-N labels
    messages.append(.user(analysisFirstUser(detail, human, t)))
    onStage(.identifyingSpeakers)
    let raw = try await session.generate(messages: messages, options: speakerOptions)   // buffered
    try await persistSpeakers(raw, ctx)                                          // parse → findOrCreatePerson → setSpeakerAssignments (skips userSet)
    messages.append(.assistant(raw))                                            // feed model output back VERBATIM (max KV reuse)
    if ctx.doSummary { messages.append(.user(summaryFollowUpUser)) }
} else if ctx.doSummary {
    let names = ctx.human.mapValues(\.name)                                      // resolved human names
    let t = TranscriptFormatter.plain(ctx.transcript, names: names)
    messages.append(.user(summaryOnlyFirstUser(detail, t)))
}

if ctx.doSummary {
    onStage(.summarizing)
    try await streamAndPersistSummary(session, messages, ctx)                    // generateStreaming → accumulate → applyGeneratedSummary
}
```

- `persistSpeakers`: `SpeakerMappingParser.parse(raw)` → for each entry
  `store.findOrCreatePerson(name:email:)` → `store.setSpeakerAssignments(assignments, for:
  transcript.id)`. (Empty/malformed parse → no assignments, no throw; summary still runs.)
- `streamAndPersistSummary`: mirrors the current `Summarizer.run` loop — accumulate `.token`,
  push `onPartialSummary`, use `.done(result).text` as canonical, then
  `store.applyGeneratedSummary(accumulated, for: meetingID)`.
- Cases handled: A = both (multi-turn, transcript reused), B = speakers-only, C = summary-only
  (single turn, human names in transcript), D = neither is never passed in (caller guards).

### 4.5 `Intelligence` orchestration

Both entry points compute `(doSpeakers, doSummary)`, size context once, and call
`MeetingAnalyzer.run` inside one `llm.withSession(config: .modelOnly)`.

Shared gating helper:

```swift
// doSpeakers: run the speaker turn iff ≥1 transcript speaker is NOT human-set
let human = (try? await store.humanSetSpeakerMappings(for: transcript.id)) ?? [:]
let allIDs = Set(transcript.segments.compactMap(\.speakerID))
let doSpeakers = !allIDs.subtracting(Set(human.keys)).isEmpty
```

`runAutoEnhancements(meetingID:)` (signature unchanged):
- `guard settings.enabled` (replaces the two-toggle OR), `guard models.isDownloaded()`,
  load `detail` + `preferredTranscript`.
- `doSummary = !detail.editedSummary`; `doSpeakers` per helper.
- `guard doSpeakers || doSummary else { … }` (no session otherwise).
- Status flow via `onStage`: `.preparing` (set synchronously, as today) →
  `.identifyingSpeakers` → `.summarizing` → `.completed` (or `.failed`).

`generateSummary(meetingID:transcriptID:force:)` is **renamed**
`runAnalysis(meetingID:transcriptID:force:)` (manual path; one VM call site updated):
- **Not** gated by `settings.enabled` (manual intent always works if model present).
- `guard models.isDownloaded()`.
- Load `detail` + `transcript(id: transcriptID)`.
- `doSummary`: if `detail.editedSummary && !force` → return (caller shows confirm; on confirm
  passes `force: true`). Otherwise `true`.
- `doSpeakers` per helper (fills non-human-set speakers; this is what gives older meetings a
  UI path to speaker inference).
- Same `onStage` flow.

### 4.6 Context sizing (`ContextSizing.swift`)

Per-task output reservation with an always-on conversation buffer. The transcript is counted
**once**; each active task reserves its own output budget:

```
base    = countTokens([system, firstUser] + followUpUsers)
reserve = 1024                                    // always-on conversation buffer
        + (doSpeakers ? 512  : 0)                 // speaker output reserve (= speakerOptions.maxTokens)
        + (doTitle    ? 128  : 0)                  // title output reserve (deliberately > titleOptions.maxTokens 32)
        + (doSummary  ? 2048 + round(0.15 × base) : 0)   // summary: base 2048 + 15% of input
size    = min(base + reserve, 49152)               // cap 48k (Gemma supports well beyond)
```

The 1024 buffer guarantees headroom even on speakers-only / title-only runs. When summary is
present, `1024 + 2048 + 15% = 3072 + 15%` reconciles with the old single-output reservation;
speakers/title add on top. The old positional `outputReservation(forInputTokens:)` /
`contextSize(forInputTokens:)` / `outputReservationBase` helpers are removed (dead after this
change).

---

## 5. BiscottiKit — UI (Phase 4)

### 5.1 SettingsUI

`SettingsViewModel`: remove `summarizeTranscripts` / `guessSpeakerNames` published props,
their bindings, and `setSummarizeTranscripts` / `setGuessSpeakerNames`. Add
`aiAnalysisEnabled` + `setAIAnalysisEnabled(_:)` (writes `settings.aiAnalysisEnabled`) and
load it in `refreshData`.

`SettingsView.aiEnhancementsSection`: one toggle, disabled when `!modelAvailable`:
- Title: **"AI Analysis & Summary"**
- Caption: **"Generate a summary from the transcript, and guess the names of speakers from context."**

### 5.2 MeetingDetailUI

`MeetingDetailViewModel`:
- Replace `summarizeEnabled` / `guessSpeakersEnabled` with `aiAnalysisEnabled` (loaded in
  `refreshData`). `pipelineStages` keeps **both** stages ("Identifying speakers",
  "Summarizing"); gate both on `aiAnalysisEnabled && modelAvailable`; the "Summarizing" stage
  remains hidden on auto-run when `editedSummary` (it shows on manual regenerate).
- `runSummary(force:)` → calls `core.intelligence.runAnalysis(meetingID:transcriptID:force:)`
  (the combined analysis). `generateSummary()` keeps the edited-summary confirm (`force` on
  confirm). `canRegenerateSummary` (`displayedTranscript != nil && modelAvailable`) is
  unchanged — **not** gated by the toggle.
- The overflow "Regenerate Summary" item and the Summary-tab empty-state "Generate Summary"
  button both call this same path; label text unchanged.

No change to speaker-name display, the speaker-mapping sheet, or `MarkdownEditor` — manual
assignment still writes `userSet == true` via `setSpeakerAssignment`.

---

## 6. Manual-test app (Phases 1–2)

`ManualTestKit/Scripts/LocalLLMScript.swift` + `ManualTestApp/Sources/WiredScripts.swift`
(`wireLocalLLM`). All `llm_*` recordable steps are marked **not-run** when the service
changes (staleness rule) and a human re-runs them on hardware.

- **Phase 1:** update every existing inference call site to the messages API (single-turn =
  `[.user(prompt)]`). Add one step `llm_chat_system` that runs a `[.system(…), .user(…)]`
  call to confirm system framing survives the format change (+ a `humanQuestion`).
- **Phase 2:** add `llm_kv_reuse` — within **one** `LLMService.withConnection`:
  1. `generate([.system(A), .user(B)], …) → C`, show `cachedPromptTokenCount` (≈0) and prompt
     eval ms.
  2. `generate([.system(A), .user(B), .assistant(C), .user(D)], …) → E`, show
     `cachedPromptTokenCount` (≈ tokens of A+B) and prompt eval ms.
  Use a large `B` (a transcript) so the latency drop is obvious. Add an `.instruction`
  explaining what to look for, and a `humanQuestion` ("did the 2nd call reuse most of the
  prefix — high cached count, much faster prompt eval — and was E coherent?"). The coherence
  check is also the on-hardware guard for the §2.3 position risk.

Use `ResultsStore.markScriptNotRun(scriptID:allStepIDs: recordableStepIDs(in:))` (skip
`.instruction` IDs) or hand-edit `manual_test_results.json` per CLAUDE.md.

---

## 7. Error handling

- **Engine reuse:** any error/cancel clears KV + resets `cachedTokens` (§2.5). Context
  overflow throws `LocalLLMError.contextOverflow` using the full prompt length.
- **Analysis:** transport/generation errors throw → `EnhancementStatus.failed(message:)`
  (same as today). Empty/malformed speaker parse is **not** an error — summary proceeds.
  `CancellationError` → status removed (run abandoned), same as today.
- **In-flight guard** (`inFlightMeetingID`) and the streaming/partial handling are unchanged.
- **DataStore:** `humanSetSpeakerMappings` throws `DataStoreError.notFound` for a missing
  transcript; Intelligence treats a failed read as "no human mappings" (`?? [:]`) and
  proceeds (worst case it re-guesses a speaker, still protected on write).

---

## 8. Testing strategy

**LocalLLM (`make test`, MockEngine — no model):**
- `ChatTemplate`: multi-turn rendering; single/two-message parity with the pinned legacy
  strings; thinking-on/off; no-system-with-thinking edge; assistant-turn rendering.
- `commonPrefixLength`: empty, identical, divergent-at-k, prefix-shorter cases.
- DTO `Codable` round-trip for the new `messages` payloads.
- `LLMConnection` + `MockEngine`: messages flow through generate/streaming/countTokens.

**LocalLLM KV reuse (`make test-ai`, real model — heavy, human-run):**
- Two-turn extend within one connection: assert `cachedPromptTokenCount` ≈ tokens(prefix) on
  turn 2, ≈0 on turn 1, and that turn-2 output is coherent (guards the position mechanism).

**Intelligence (`make test`, FakeLLMSession + in-memory DataStore) — the functional-spec
unit-test requirements:**
- Prompt builders: `<meeting_details>` field omission (missing title/end/location/conference/
  description); `userSpeakerMappingBlock` only for human-set and omitted when empty;
  transcript labels (Speaker-N vs resolved names) in cases A/C; turn ordering.
- Gating truth table: `doSpeakers` iff ≥1 non-human-set speaker; `doSummary` =
  `!editedSummary` (auto) / forced (manual); no-session when both false; manual `runAnalysis`
  ignores `settings.enabled`.
- `MeetingAnalyzer` with a `FakeLLMSession` that records the per-call `messages`: turn-1 =
  `[system, user1]`; turn-2 = `[system, user1, assistant1, user2]` with `assistant1` equal to
  the model's verbatim output; speaker persistence called with parsed assignments; summary
  persisted; case-C single-turn path.
- Write-side protection: `setSpeakerAssignments` skips `userSet` entries (keep/extend existing
  test); `humanSetSpeakerMappings` returns only human-set, drops dangling.

**UI:** existing SettingsUI/MeetingDetailUI view-model tests updated for the single flag and
the combined regenerate path.

**Manual:** the two new steps (§6), plus the existing `llm_*` re-run on hardware.

---

## 9. Design decisions & rationale

- **Diff-based reuse over token-accumulation bookkeeping.** Re-rendering the whole
  conversation and diffing freshly-tokenized tokens against the resident KV tokens makes
  reuse correctness independent of tokenizer composability; the client stays stateless
  (always sends the full list, exactly as the user specified). Cost: re-tokenizing the full
  prompt each call — negligible vs. decode.
- **Reuse is a perf optimization, never a correctness dependency.** Every error path clears
  it; a prefix mismatch just re-decodes more. This keeps the risky llama.cpp interaction
  contained and falsifiable by one manual-test step.
- **Single message type across layers.** `LLMMessage` lives in LocalLLM and is reused by
  BiscottiKit (no parallel type), so the conversation is built once and flows unchanged to
  the engine.
- **Manual regenerate decoupled from the auto toggle.** The toggle governs automation; the
  button is explicit intent. This is what closes the "infer speakers on older meetings" gap
  without a new control.
- **No new long-transcript truncation.** Out of scope (functional spec §1); the existing
  count-tokens + reconfigure + `contextOverflow` behavior is preserved, now counting the
  transcript once.
```

## 10. BiscottiKit — Title Generation (Phase 5)

Adds a third turn (title) to the analysis conversation. **No LocalLLM changes** — this is
entirely BiscottiKit (DataStore + Intelligence), so `llm_*` manual tests are unaffected.

### 10.1 Shared default-title constant (DataStore)

Promote the hard-coded `"Untitled Meeting"` to a single source of truth so the gate and the
write reference the same value:

- Add `public static let defaultTitle = "Untitled Meeting"` to the `Meeting` model (DataStore).
- Refactor `RecordingController.autoTitle()` to return `Meeting.defaultTitle` (behavior
  identical; removes the duplicated literal).

### 10.2 `MeetingDetailData.editedTitle` (DataStore read model)

`MeetingDetailData` currently exposes `title` and `editedSummary` but not `editedTitle`. Add
`public let editedTitle: Bool` (default `false` in the memberwise init) and map it in
`meetingDetail` (`editedTitle: meeting.editedTitle`, alongside the existing `editedSummary`
mapping). The Intelligence gate reads it.

### 10.3 `applyGeneratedTitle` (DataStore + LLMFeatures)

New write method mirroring `applyGeneratedSummary`, but with an **internal gate** (authoritative
enforcement, mirroring `applyEventTitle`'s `!editedTitle` guard):

```swift
/// Stores an AI-generated title IFF the meeting still has the default title
/// and the user has not renamed it. Leaves `editedTitle == false` so a later
/// calendar association can still apply a real event title. No-op otherwise.
func applyGeneratedTitle(_ title: String, for meetingID: UUID) throws {
    guard let meeting = try meeting(id: meetingID) else { throw DataStoreError.notFound(meetingID) }
    guard meeting.title == Meeting.defaultTitle, !meeting.editedTitle else { return }
    meeting.title = title
    try save()
}
```

### 10.4 Prompt catalog additions (`IntelligencePrompts.swift`)

- `titleTaskInstructions` — asks for a concise, specific title (a few words / short phrase) that
  captures the meeting's main topic; output a single bare line, no quotes, no `Title:` label, no
  trailing punctuation.
- `titleFollowUpUser = titleTaskInstructions` — used when the transcript is already in context.
- `titleOnlyFirstUser(detail:transcriptNamed:)` — used when no prior turn ran: meeting-details
  block + `<transcript>` (resolved names) + `titleTaskInstructions` (parallels
  `summaryOnlyFirstUser`).

### 10.5 `MeetingAnalyzer` — the title turn

- Add `titleOptions = GenerationOptions(maxTokens: 32, temperature: 0.3, thinking: .off)`.
- Add `doTitle: Bool` to `Context`.
- **Uniform turn threading.** Refactor `run` so each turn appends its own user message and its
  assistant reply to a single `inout messages` array, then the next turn follows. This is
  behavior-preserving for the wire (the LLM sees the identical sequence as today for the
  speakers/summary turns); it just lets the title turn build on the summary reply:
  - speaker turn: append `analysisFirstUser`, generate, persist, append `.assistant(reply)`.
  - summary turn: append (`summaryFollowUpUser` if a prior turn ran, else `summaryOnlyFirstUser`),
    stream, persist, append `.assistant(summary)`.
  - title turn: append (`titleFollowUpUser` if `doSpeakers || doSummary`, else
    `titleOnlyFirstUser`), buffered `generate` with `titleOptions`, clean, persist via
    `applyGeneratedTitle`.
- Emit `ctx.onStage(.generatingTitle)` at the start of the title turn.
- **Title cleaning** (pure helper, unit-tested): trim whitespace/newlines; take the first
  non-empty line; strip a leading `Title:`/`Title -` prefix; strip surrounding matching quotes;
  trim again; defensively cap length; return `nil` if empty (caller skips the write). Reuses the
  `SpeakerMappingParser`/`TranscriptFormatter` style of small pure parsers.

### 10.6 `EnhancementStatus.generatingTitle`

Add a `case generatingTitle` to `EnhancementStatus`. Update the exhaustive switches over it
(MeetingDetailUI status → label/pill) with a "Generating title…" label. (The compiler enforces
exhaustiveness; find all sites.)

### 10.7 `Intelligence` orchestration + context sizing

- In `runAnalysisSession`, compute `doTitle` from the snapshot:
  `let doTitle = detail.title == Meeting.defaultTitle && !detail.editedTitle`.
- Relax the early-out guard: `guard doSpeakers || doSummary || doTitle else { return }`.
- Thread `doTitle` into `MeetingAnalyzer.Context`.
- **Context sizing uses per-task output reservation** (see §4.6). `contextSizeForAnalysis` now
  takes `doSpeakers`/`doSummary`/`doTitle` booleans directly and computes the reserve internally.
  `Intelligence.contextBudgetFollowUps` returns only the follow-up user turns (the output budget
  is no longer the caller's responsibility). The always-on 1024 buffer + per-task reserves
  (speaker 512, title 128, summary 2048 + 15%) replace the old positional scheme. Cap raised to
  49152 (48k) so the multi-turn conversation isn't clipped.
- Update `buildFirstUserContent` only if needed (the title-only first-user path is reachable when
  `!doSpeakers && !doSummary && doTitle` — size it with `titleOnlyFirstUser`).

### 10.8 SettingsUI caption (minor)

Update the single-toggle caption to mention titles, e.g. *"Generate a title and summary from the
transcript, and guess the names of speakers from context."* (string-only; the toggle itself is
unchanged).

### 10.9 Testing

- DataStore: `applyGeneratedTitle` writes when default+not-edited; no-ops when title is
  non-default or `editedTitle == true`; leaves `editedTitle == false`. `Meeting.defaultTitle`
  used by `RecordingController.autoTitle()`.
- Prompt builders: `titleOnlyFirstUser` structure; `titleFollowUpUser` == instructions.
- Title cleaning: quotes/label/multiline/empty cases.
- `MeetingAnalyzer` message sequencing (FakeLLMSession): the four `doTitle` combinations produce
  the sequences in functional spec §11.4; the title follow-up contains **no** second transcript;
  `applyGeneratedTitle` is invoked with the cleaned title.
- Intelligence gating truth table: `doTitle` true only when default+not-edited; independent of
  `force`; title turn skipped otherwise; runs on both auto and manual paths.
- ContextSizing: per-task `doSpeakers`/`doSummary`/`doTitle` reservation math, 49152 cap.
