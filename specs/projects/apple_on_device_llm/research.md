---
status: draft
---

# Research: Apple on-device LLMs (Foundation Models framework)

Answers the five research questions from `project_overview.md`. Sources are Apple's
current developer documentation (fetched 2026-08-31, includes macOS 27 beta symbols),
Apple Technote TN3193, and WWDC25/26 session material. Anything marked
**[verify]** needs an on-hardware manual test before we design against it.

---

## 0. Headline verdict

**The API shape is compatible. The context window is not.**

Apple's on-device model exposes a session/prompt/stream API that maps cleanly onto
`LLMSession` with a small number of well-understood gaps. Swapping it in behind a
model-selection parameter is genuinely feasible.

But Apple's on-device foundation model has a **fixed context window of 4096 tokens
(macOS 26.0–26.3) / 8192 tokens (current generation)** — shared between input *and*
output, per session. Biscotti's analysis puts a **whole meeting transcript in one
user turn**: `specs/projects/improve_ai_analysis/functional_spec.md` records
"~20k tokens for a long meeting," and `ContextSizing.maxContextSize` is 48k. Even a
15-minute meeting (~3.5k tokens) plus the system prompt plus a 2048-token summary
reserve overflows 8192.

So this is not a drop-in third catalog entry. Adopting the Apple model means either
(a) restricting it to short meetings and telling the user why, or (b) building a
chunked map-reduce analysis path — which is exactly what Apple's own technote
recommends for long documents. That is a product decision, and it is the main thing
this project has to settle before architecture. See §7.

---

## 1. API structure & compatibility with our interface

### The Foundation Models shape

```swift
import FoundationModels                       // macOS 26.0+

let model = SystemLanguageModel.default        // or SystemLanguageModel(useCase:guardrails:)
guard case .available = model.availability else { … }

let session = LanguageModelSession(model: model, tools: [], instructions: "…")
session.prewarm(promptPrefix: nil)

let response = try await session.respond(
    to: "…", options: GenerationOptions(temperature: 0.6, maximumResponseTokens: 2048)
)
response.content                               // String
response.usage.input.totalTokenCount           // macOS 27 beta
```

Key structural difference: **an FM session owns its own transcript.** You create the
session once with `instructions:`, then send only the *new* user turn on each
`respond`. Our `LLMSession.generate(messages:)` re-sends the whole conversation each
call and the engine diffs it for KV reuse. An Apple adapter therefore has to hold one
`LanguageModelSession` for the life of our session and treat each incoming `messages`
array as a prefix-extension of the last one (sending only the tail). Our
`MeetingAnalyzer` already appends strictly — it never rewrites history — so this holds.

### Mapping onto `LLMSession` / `LLMConnection`

| Our API | Foundation Models | Verdict |
|---|---|---|
| `LLMService.withConnection(model: URL, …)` | no file path — the model is a system asset | **breaks**: needs a model *reference* (enum), not a `URL` |
| `generate(messages:options:) -> String` | `session.respond(to:options:) -> Response<String>` | clean |
| `generateStreaming(...) -> AsyncThrowingStream<StreamEvent, …>` | `session.streamResponse(to:options:) -> ResponseStream<String>` | works, but see streaming note below |
| `countTokens(messages:)` | `model.tokenCount(for:)` (Instructions / Prompt / Transcript.Entry overloads) | works, **macOS 26.4+ only** |
| `reconfigure(contextSize:)` | — | **no-op**: FM's window is fixed; read `model.contextSize` instead |
| `LLMMessage.system` | `LanguageModelSession(instructions:)` | maps, but set at session creation |
| `.user` / `.assistant` | `Prompt` / session transcript | maps |
| `cancel()` | Task cancellation on `respond` | **[verify]** — not documented explicitly |
| one in-flight request per connection | FM enforces the same (`concurrentRequests` error) | already aligned |

### `GenerationOptions` gaps

FM offers exactly three knobs: `temperature`, `samplingMode`, `maximumResponseTokens`.

| Ours | FM | Notes |
|---|---|---|
| `temperature` | `temperature: Double?` | direct |
| `maxTokens` | `maximumResponseTokens: Int?` | direct — but Apple warns it truncates mid-sentence rather than wrapping up; use prompt-level length steering instead |
| `topK` | `.random(top: Int, seed: UInt64?)` | available, **mutually exclusive** with top-P |
| `topP` | `.random(probabilityThreshold: Double, seed:)` | available, mutually exclusive with top-K |
| `temperature == 0` | `.greedy` | direct |
| `seed` | carried on the `.random(…)` sampling modes | direct |
| `minP` | — | **unsupported** |
| `repeatPenalty` / `repeatLastN` | — | **unsupported** |
| `stopSequences` | — | **unsupported** |
| `applyChatTemplate: false` (raw mode) | — | **unsupported** — FM owns the template |
| `thinking` | `ContextOptions.ReasoningLevel` (`.light/.moderate/.deep/.custom`) | macOS 27 beta only; primarily a PCC feature |

Our `MeetingAnalyzer` only uses `maxTokens`, `temperature`, and `thinking: .off`, so
the unsupported knobs cost us nothing in the app path. They do mean the LocalLLM CLI
and the ManualTestApp tab can't expose the full slider set for this backend.

### `GenerationResult` gaps

| Field | FM source |
|---|---|
| `promptTokenCount` | `response.usage.input.totalTokenCount` — **macOS 27 beta only** |
| `cachedPromptTokenCount` | `response.usage.input.cachedTokenCount` — **macOS 27 beta only** |
| `generatedTokenCount` | `response.usage.output.totalTokenCount` — **macOS 27 beta only** |
| durations | we measure them ourselves |
| `finishReason` | **unavailable** — no equivalent |
| `renderedPrompt` / `rawText` | **unavailable** — FM never exposes the rendered prompt |
| `reasoning` | not separately surfaced on-device (only `reasoningTokenCount`) |

On macOS 26.x there is no `usage` at all, so token stats would have to come from a
separate `tokenCount(for:)` call (26.4+) or be reported as zero.

### Streaming semantics

`ResponseStream` "produces aggregated tokens" — each snapshot is the **cumulative**
response so far, not a delta. Our `StreamEvent.token(String)` is a delta. The adapter
must diff consecutive snapshots. Mechanical, but don't miss it.

Apple also advises using non-streaming `respond` when the process is in the
background, because streaming burns more power and hits the rate limiter sooner (§6).

### Does it fit inside `BiscottiLLM.xpc`?

Yes, and it costs nothing — but it also *buys* nothing. FM is a thin client to a
system daemon; the weights never enter our process, so the XPC service's reason for
existing (reclaiming multi-GB of RSS on close) doesn't apply. Routing the Apple
backend through the same XPC service keeps one code path and one interface, which is
worth more than the saved hop. **[verify]** that `SystemLanguageModel` reports
`.available` from inside an XPC service in a Developer ID-signed, non-sandboxed,
hardened-runtime app — no entitlement is documented as required, but this is exactly
the kind of thing that surprises you on hardware.

---

## 2. Detecting what's available

There is no "installed models" list. There is one system model, and one availability
check:

```swift
switch SystemLanguageModel.default.availability {
case .available:                              …
case .unavailable(.deviceNotEligible):        // hardware can't run Apple Intelligence
case .unavailable(.appleIntelligenceNotEnabled): // user hasn't turned it on
case .unavailable(.modelNotReady):            // downloading, or other system reason
case .unavailable(let other):                 // unknown — enum is not frozen-exhaustive
}
```

`isAvailable: Bool` is the shorthand. macOS 27 beta adds
`SystemLanguageModel.Error.assetsUnavailable(_:)` for asset failures surfaced as
thrown errors rather than an availability state.

This maps well onto `ModelProviding`:

- `deviceNotEligible` → the same UI state as `ModelBlockedReason.cannotRun` (grey out).
- `appleIntelligenceNotEnabled` → a *new* state: not "download this", but "turn this
  on in System Settings." Needs its own row treatment.
- `modelNotReady` → equivalent to "downloading", but with **no progress fraction**
  and no way to start it (§5).

**Availability is dynamic.** The user can toggle Apple Intelligence off at any time,
and the model can be evicted. Unlike a GGUF on disk, presence is not sticky — so
`ModelManager.activeModelID` must re-check at run time, not just at refresh time, and
the analysis path needs a graceful fallback when the selected Apple model has gone
away mid-session.

---

## 3. Model quality: variants and the "min quality" gate

Two independent axes.

**Axis 1 — OS version.** Apple documents three distinct on-device model generations:

| macOS | Model generation |
|---|---|
| 26.0 – 26.3 | 1st gen, 4096-token context |
| 26.4 | 2nd gen |
| 27.0 | AFM 3, 8192-token context |

The documented way to branch on this is a plain `if #available(macOS 26.4, *)` check
(Apple's own guidance in *Updating prompts for new model versions*). So an
OS-version floor is straightforward to implement and is the most reliable quality
signal we have.

**Axis 2 — Variant (macOS 27 beta).** New in 27:

```swift
model.variant                     // SystemLanguageModel.Variant
SystemLanguageModel.Variant.core3          // "AFM 3 Core"
SystemLanguageModel.Variant.coreAdvanced3  // "AFM 3 Core Advanced"
model.variant.displayName         // user-facing string
```

Reported industry detail (not in Apple's docs): Core Advanced is a ~20B-parameter
model held in flash that pages a small set of experts into DRAM per prompt,
activating roughly 1–4B parameters. Core is the smaller always-resident model.
Which one a Mac gets is presumably a hardware/RAM decision by the system.

**Critical constraint: the variant is read-only.** There is no
`SystemLanguageModel(variant:)` initializer — the full initializer list is
`default` and `init(useCase:guardrails:)`. You find out which model you got; you
cannot ask for a better one.

That makes "min model quality" a **gate, not a preference**: read
`(osVersion, variant, contextSize)`, compare against the user's floor, and if the
machine is below it, mark the Apple option unavailable with a reason and fall back to
Gemma. There's a nice property here: `contextSize` is itself the most honest quality
signal for our workload, it's readable on every version (back-deployed to 26.4 and
present earlier), and it's the number that actually decides whether a given meeting
fits. **[verify]** what `variant` reports on 26.x — likely unavailable, since the
symbol is 27.0+.

---

## 4. Can we trigger the download?

**No.** There is no download API, no progress reporting, and no way to initiate the
fetch from an app. The assets come down when the user enables Apple Intelligence in
System Settings; until then `availability` is `.appleIntelligenceNotEnabled`, and
while it's in flight it's `.modelNotReady` with no fraction.

The most we can do is deep-link the user into System Settings via the
`x-apple.systempreferences:` URL scheme and poll `availability`. **[verify]** the
exact pane identifier for the Apple Intelligence & Siri pane on macOS 26/27 — the
scheme is well established but this specific pane's bundle id needs checking on
hardware.

Consequence for the UI: the Apple row in Manage Models is **not** a download row. It's
a "Turn on Apple Intelligence" row, or a "Downloading…" row with an indeterminate
spinner, or a "Not supported on this Mac" row. It shares almost none of the download
machinery with the Gemma rows, and modelling it as a third `LLMModel` with a
`downloadURL` and `approxDownloadBytes` would be a lie. `LLMModel` needs to grow a
provenance/kind distinction, or the Apple option needs to live beside the catalog
rather than inside it.

---

## 5. Gotchas, limits, and things worth knowing

**Context window — the blocker.** 4096 tokens (26.0–26.3) or 8192 (current), shared
across instructions + all prompts + all responses in a session. Read it at runtime
via `model.contextSize`; don't hardcode. Overflow throws
`GenerationError.exceededContextWindowSize` and the session is then dead — you must
build a new one. Apple's TN3193 explicitly prescribes chunked map-reduce for long
documents: summarize chunks in fresh sessions, feed the previous chunk's summary
forward for continuity, then combine.

**Guardrails — manageable, and important to get right.** Default guardrails check
both prompt and output and throw `guardrailViolation`. Real meeting audio contains
profanity, conflict, layoffs, medical and legal talk — a false positive here means a
user's actual meeting silently fails to summarize. Mitigation exists:

```swift
let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
```

This skips guardrail checks **for plain string generation only** — which is exactly
what Biscotti does (summary, speaker mapping, title are all strings). If we ever move
to guided generation, guardrails come back. Even in permissive mode the model may
still emit a soft refusal ("Sorry, I can't help with that") as ordinary text, which we
cannot detect programmatically. Apple notes guardrail false positives were reduced in
26.4 and further in 27.

**Rate limiting.** `rateLimited` is thrown when the process runs in the **background**
on **battery** and exceeds a system limit. Biscotti is a menu-bar app that auto-runs
analysis right after a meeting ends — frequently not the foreground app, frequently on
battery. **[verify] on hardware**: this is the gotcha most likely to bite us in
normal use, and the mitigation (prefer non-streaming `respond` in the background) has
a real UX cost — the Summary tab currently streams.

**Language.** The model only handles Apple Intelligence-supported languages, and
throws `unsupportedLanguageOrLocale` when the *prompt content* is in an unsupported
one. Check `supportsLocale(_:)` up front, but note the transcript's language may
differ from the app locale.

**Deployment target.** Biscotti targets macOS 15.0; FoundationModels is macOS 26.0+
and `Variant` is 27.0+. Every FM call site needs `@available` / `#available`
guarding, and the Apple option must be absent (not merely disabled) on macOS 15.

**Other errors to handle:** `refusal`, `concurrentRequests`,
`assetsUnavailable`, `timeout`.

**No adapter/fine-tune path** that's relevant here, and **no custom vocabulary hook** —
our `Vocabulary` module feeds transcription, not the LLM, so this is unaffected.

**Interesting inversion (out of scope, worth noting):** macOS 27 adds a public
`LanguageModel` protocol so any engine can back a `LanguageModelSession`. We could in
principle expose our llama.cpp engine through it. That's the opposite of this
project and buys us nothing today, but it's the direction Apple's API is moving.

---

## 6. What this means for the project

The API-compatibility answer to the overview's question is **yes, with a caveat that
matters more than the compatibility does**:

1. `LLMService.withConnection(model: URL, …)` must become a model *reference*, not a
   path. That's the "model selection param" — a small, clean change, and it's the
   right change regardless.
2. `reconfigure(contextSize:)` becomes advisory (no-op for Apple).
3. The unsupported sampling knobs and missing `finishReason` / debug fields are real
   but don't affect the app path.
4. The catalog/download model in `ModelProviding` + `ModelManager` + Manage Models
   does **not** fit an Apple entry. It needs a kind distinction.
5. **The context window forces a product decision.** Options, roughly:
   - **A — Ship it gated.** Offer the Apple model, compute the transcript's token
     count up front, and if it doesn't fit, tell the user this meeting is too long
     for the Apple model and fall back to Gemma (or skip). Cheapest; honest; means
     the Apple option silently does nothing for most real meetings.
   - **B — Chunked map-reduce analysis.** Build the chunk/summarize/combine path
     Apple recommends. Makes the Apple model genuinely useful, and would also let
     Gemma handle transcripts longer than its window. Much larger project, and
     summary quality on a 8k-window model over a chunked hour-long meeting is an
     open question we'd want to test before committing.
   - **C — Research spike only.** Land the availability/detection/quality-gate
     plumbing and a ManualTestApp tab, prove the quality on real meetings, and defer
     the product decision.

---

## 7. Open questions for hardware validation

- [ ] Does `SystemLanguageModel.default.availability` report `.available` from inside
      `BiscottiLLM.xpc` (Developer ID, hardened runtime, non-sandboxed)?
- [ ] Does `Task` cancellation actually stop an in-flight `respond` / `streamResponse`?
- [ ] Does a menu-bar app doing post-meeting analysis get `rateLimited` on battery?
- [ ] What does `contextSize` actually report on the target OS build (8192?), and
      what does `variant.displayName` report on this Mac?
- [ ] Does `permissiveContentTransformations` reliably clear real meeting content, and
      how often do soft refusals appear in the response text?
- [ ] Which `x-apple.systempreferences:` identifier opens the Apple Intelligence pane?
- [ ] Summary quality on a real meeting vs. Gemma 4 E2B — is the Apple model actually
      competitive at our task?
