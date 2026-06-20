---
status: complete
---

# Component: `Intelligence` module

The in-process owner of all Biscotti LLM scenario logic. BiscottiKit target depending on `DataStore` + `LocalLLM`. Public surface is in `architecture.md` §4.1; this doc is the internals.

## File layout (`Packages/BiscottiKit/Sources/Intelligence/`)
```
Intelligence.swift            // @MainActor @Observable service; public API; orchestration + download state machine
EnhancementStatus.swift       // status + ModelDownloadState + AISettings enums
LLMRunning.swift              // LLMRunning / LLMSession protocols
LiveLLMRunning.swift          // real impl over LLMService.withConnection / LLMConnection
ModelProviding.swift          // ModelProviding protocol
LiveModelProvider.swift       // real impl over ModelDownloader + LocalLLMPaths
IntelligencePrompts.swift     // Swift-constant prompt catalog (system prompts + user builders)
TranscriptFormatter.swift     // segments + name map -> plain-text turns
SpeakerMappingParser.swift    // "idx | name | email" line parser
SpeakerIdentifier.swift       // speaker-ID step (build -> generate -> parse -> resolve -> persist)
Summarizer.swift              // summary step (build -> stream -> persist)
```

> **Note:** The original design listed a separate `ModelManager.swift` for the download
> state machine. In implementation, the download state machine was inlined into
> `Intelligence.swift` — the logic is small (a single `downloadModel()` method +
> `refreshModelState()`) and didn't warrant a separate type.

## Orchestration — `runAutoEnhancements(meetingID:)`
```
guard inFlight == nil else { return }          // single in-flight (also clear at end via defer)
inFlight = meetingID
let s = await settings()                        // AISettings
guard models.isDownloaded() else { return }
guard s.summarize || s.guessSpeakers else { return }
guard let detail = try? await store.meetingDetail(id: meetingID),
      let transcript = detail.preferredTranscript else { return }

do {
  try await llm.withSession { session in        // ONE session = model loaded once
    var nameMap: [Int: String] = transcript.speakerAssignments.mapValues(\.name)  // existing names (rare on fresh)
    if s.guessSpeakers {
      jobs[meetingID] = .identifyingSpeakers
      let assignments = try await SpeakerIdentifier.run(session, transcript, invitees(detail), store)
      nameMap = assignments                       // speakerID -> resolved name
    }
    if s.summarize && !detail.editedSummary {
      jobs[meetingID] = .summarizing
      try await Summarizer.run(session, meetingID, transcript, nameMap, store) { partial in
        streamingSummary[meetingID] = partial
      }
    }
  }
  jobs[meetingID] = .completed
} catch is CancellationError { /* leave clean */ }
catch { jobs[meetingID] = .failed(message: short(error)) }
streamingSummary[meetingID] = nil
// inFlight cleared by defer; jobs[meetingID] cleared shortly after .completed (UI reloads on it)
```
- Speaker-ID **always precedes** summary so the summary user message uses real names.
- `generateSummary(meetingID:transcriptID:force:)` is the manual path: same `llm.withSession` but **summary only**, on the passed `transcriptID`; `force` is set by callers that already confirmed the edited-summary overwrite. (Empty/auto summaries pass `force: false` but there's nothing to guard, so it runs.)

## `SpeakerIdentifier`
```
let user = IntelligencePrompts.speakerUser(transcript: TranscriptFormatter.plain(transcript, names: [:]),
                                           invitees: invitees)        // labels stay "Speaker N" in the prompt
let raw = try await session.generate(system: IntelligencePrompts.speakerSystem,
                                     user: user, options: .speakerID)
let parsed = SpeakerMappingParser.parse(raw)                          // [Int: (name, email?)]
var assignments: [Int: UUID] = [:]
for (id, who) in parsed {
    assignments[id] = try await store.findOrCreatePerson(name: who.name, email: who.email)
}
try await store.setSpeakerAssignments(assignments, for: transcript.id)
return resolved names ([Int: String]) for the summary step
```
- `GenerationOptions.speakerID`: low temperature (e.g. `temperature: 0.2`, greedy-ish), `maxTokens` small (a few hundred — one short line per speaker), `thinking: .off`, no stop sequences. Non-streaming.

## `Summarizer`
```
let user = IntelligencePrompts.summaryUser(transcript: TranscriptFormatter.plain(transcript, names: nameMap))
var acc = ""
for try await event in session.generateStreaming(system: IntelligencePrompts.summarySystem,
                                                  user: user, options: .summary) {
    switch event {
    case .token(let t): acc += t; onPartial(acc)
    case .done(let result): acc = result.text          // canonical final text
    default: break
    }
}
try await store.applyGeneratedSummary(acc, for: meetingID)            // editedSummary = false
```
- `GenerationOptions.summary`: `maxTokens` generous (e.g. 1500–2048), moderate temperature (e.g. 0.6), `thinking: .off`, `applyChatTemplate: true`. Streamed.
- Reasoning tokens (if any) are ignored for display (`thinking: .off`).

## `IntelligencePrompts` (Swift constants — the reusable pattern)
A `public enum IntelligencePrompts` namespace. System prompts are `static let` multi-line strings; user messages are builder funcs. **Drafts** (final wording tuned during impl/manual test):

- `summarySystem`: instruct a concise meeting-notes writer — output **markdown only**; a short summary of decisions/topics, then a final `## Action Items` section as a `- [ ]` checklist (owners when clear); no preamble; don't invent content.
- `speakerSystem`: instruct mapping diarization speakers to real people using transcript evidence (direct address "Hi Daniel", self-intros, hand-offs) and the invitee list. **Output format is exact:** one line per *identified* speaker, `index | Full Name | email` (email blank if not from the invitee list); omit speakers you can't identify; no other text.
- `summaryUser(transcript:)` → the formatted transcript (names already applied).
- `speakerUser(transcript:invitees:)` → an invitee block (`- Full Name <email>` lines, or "No invitee list available.") + the formatted transcript (with "Speaker N" labels).

## `TranscriptFormatter`
`static func plain(_ t: TranscriptData, names: [Int: String]) -> String` → turn-per-line, e.g. `Daniel Lee: …` / `Speaker 2: …` using `names[segment.speakerID] ?? segment.speakerLabel`. Collapses consecutive same-speaker segments optionally; keeps it compact (no timestamps) to conserve context.

## `SpeakerMappingParser`
`static func parse(_ raw: String) -> [Int: (name: String, email: String?)]`
- Strip code fences/backticks; split on newlines.
- Per line: split on `|`; need ≥2 fields; field0 → `Int` (skip if non-numeric); field1 → trimmed non-empty name; field2 (optional) → email if it contains `@`, else nil.
- Ignore malformed lines; dedupe by index (last wins). Never throws.

## `ModelManager` / `LiveModelProvider`
- `LiveModelProvider`: `modelURL = ModelDownloader(cacheDirectory: LocalLLMPaths.defaultModelCacheDir).modelPath`; `isDownloaded()` = `ModelDownloader.fileExistsAndNonEmpty(at: modelURL)`; `download(progress:)` wraps `ModelDownloader.download(from:progress:)`.
- `Intelligence.downloadModel()`: `download = .downloading(nil)`; call `models.download { bytes, total in download = .downloading(total.map { Double(bytes)/Double($0) }) }`; on success `download = .downloaded` (+ `refreshModelState`); on error `download = .failed(short(error))`.
- `refreshModelState()` sets `.downloaded`/`.notDownloaded` from `isDownloaded()`; called at init and after Settings appears.

## `LiveLLMRunning`
- `withSession`: `try await LLMService.withConnection(model: models.modelURL, backend: .hosted(serviceName: "net.scosman.biscotti.BiscottiLLM")) { conn in try await body(LiveLLMSession(conn)) }`.
- `LiveLLMSession.generate` → `conn.generate(prompt: user, system: system, options:).text`; `generateStreaming` → `conn.generateStreaming(prompt: user, system: system, options:)`.
- The service name is a single constant (kept in sync with the XPC bundle id, same literal the ManualTestApp uses).

## Cancellation
Each public method runs inside the caller's Task; `withSession`/streaming honor `Task.isCancelled` (LocalLLM cancels the in-flight generate and closes the connection). On cancel: no partial summary persisted; `jobs`/`streamingSummary` cleared.

## Tests (fakes)
`FakeLLMRunning` (records system/user/options; returns scripted `generate` strings and scripted stream token sequences), `FakeModelProvider` (toggleable `isDownloaded`, scripted progress/throw), settings closure. Enables all IntelligenceTests in `architecture.md` §8 with **no model and no XPC**.
