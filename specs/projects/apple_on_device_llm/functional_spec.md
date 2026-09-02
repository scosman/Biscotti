---
status: blocked
---

# Functional Spec: Apple On-Device LLM

> **Status note:** `blocked` is not one of the spec skill's normal statuses
> (`draft` / `complete`). It is used deliberately. This spec is *finished* — it
> describes a complete, buildable feature — but the feature should **not** be built
> yet, for the reason in §1. Treat it as shelf-ready: revisit when §8's unblocking
> conditions are met, don't quietly resume it.

---

## 1. Status: BLOCKED

**Apple's on-device model has a fixed context window that is too small for Biscotti's
core job.**

The window is 4096 tokens on macOS 26.0–26.3 and 8192 on the current generation,
shared between input and output. Our analysis run puts the whole meeting transcript in
one turn. After our prompt and output reserves:

| Window | Transcript budget | Meeting length that fits |
|---|---|---|
| 4096 (macOS 26.0–26.3) | *negative* — reserves alone overflow | **nothing** |
| 8192 (current generation) | ~4,500 tokens | **~20 minutes** |

Biscotti is a meeting recorder. The meetings people most want summarized are the
hour-long ones. A model that handles the first 20 minutes is not a model we can
recommend, and shipping it as a selectable option means most users who pick it get a
fallback or a failure rather than a summary.

The feature is **not technically blocked** — everything in §4 is buildable today, and
the API compatibility is good (see `research.md` Part 1). It is **blocked on value**:
the work is real and the payoff is small until long transcripts can be handled, which
is a separate and larger project (§7).

Full analysis, including token math derived from our own prompts, is in
`research.md`.

---

## 2. Goal & Context

Biscotti runs all AI analysis (speaker identification, summary, title) through a local
LLM: one of two Gemma models the user downloads, run via llama.cpp inside the
`BiscottiLLM.xpc` service.

Apple ships an on-device LLM as part of Apple Intelligence, reachable through the
`FoundationModels` framework (macOS 26+). Where a user already has it, using it would
mean **no multi-gigabyte download** — the single biggest friction point in Biscotti's
onboarding.

This project would have added an **"Apple Intelligence" option alongside the two Gemma
models**, selected the same way, with the difference invisible to app code above the
`LLMSession` boundary.

### Non-goals

- Private Cloud Compute. Biscotti's privacy stance is local-only; PCC sends
  transcripts off-device. Its 32k window would solve the context problem, and it is
  still the wrong trade for this product.
- Third-party FM providers (Anthropic, Google) added in macOS 27. Same reason.
- Replacing Gemma. The Apple model is an additional option, never a migration.
- Exposing FM features Biscotti doesn't use: tool calling, guided generation
  (`@Generable`), multimodal prompts, adapters.

---

## 3. Why the token limit blocks it

Measured, not estimated. Our fixed prompt constants cost ~570 tokens total
(`analysisSystem` 66, `speakerTaskInstructions` 252, `summaryTaskInstructions` 196,
`titleTaskInstructions` 56). Meetings run **~230 tokens per minute** — 150 words/min
of speech plus turn labels. That reproduces the "~20k tokens for a long meeting"
figure already recorded in `improve_ai_analysis/functional_spec.md`.

A full analysis run (speakers + summary + title) carries **~3,660 tokens of overhead**:

```
system 66 + meeting details ~300 + speaker instr 252 + summary instr 196
+ title instr 56 + speaker reserve 512 + summary reserve 2,048
+ title reserve 32 + assistant echo ~200
```

Against an 8192 window that leaves ~4,500 tokens of transcript — about **20 minutes**.
Cutting the summary reserve to 1024 buys ~25 minutes. Neither is enough.

**Consequence for the design:** `contextSize >= 8192` is the real quality floor, and
it is a better gate than OS version or model variant — it's readable on every version
via `SystemLanguageModel.contextSize` (back-deployed to 26.4), and it is the number
that actually decides whether a given meeting succeeds.

---

## 4. What would be built

Specified in full so this is ready to resume, not re-derived.

### 4.1 Model catalog: a kind distinction

`LLMModel` today describes a downloadable GGUF: `downloadURL`, `fileName`,
`approxDownloadBytes`. None of those exist for the Apple model — there is no file, no
URL, and no size we control. Modelling it as a third catalog entry with fabricated
values would be a lie that leaks into the disk-space gate and the delete flow.

`LLMModel` gains a **kind**:

| Kind | Identity | Presence | Removal |
|---|---|---|---|
| `.downloadable` (both Gemmas) | `downloadURL` + `fileName` | file on disk | user deletes the file |
| `.appleSystem` | none — one system model | `SystemLanguageModel.availability` | not removable by Biscotti |

Consequences:

- `ModelInventory.isDownloaded` / `delete` / `path(for:)` apply to `.downloadable`
  only. The Apple entry answers presence from `availability` instead.
- `ModelSuitability.hasEnoughDisk` and the RAM floor do not apply to `.appleSystem`.
- `ModelProviding.download(_:progress:)` is unimplementable for `.appleSystem` and
  must reject rather than fake progress (§4.4).
- The catalog id is `apple-system`, persisted like any other selection.

### 4.2 Availability states and copy

Derived from `SystemLanguageModel.availability`, checked live. Copy follows the
existing catalog style (plain, factual, states the cost).

| State | Row copy | Action |
|---|---|---|
| `.available`, `contextSize >= 8192` | "Apple's on-device model. Already installed with Apple Intelligence — no download needed. Best for meetings under 20 minutes." | selectable |
| `.available`, `contextSize < 8192` | "Your Mac's Apple Intelligence model is too small for meeting summaries. Requires macOS 27 or later." | blocked, not selectable |
| `.unavailable(.appleIntelligenceNotEnabled)` | "Apple Intelligence isn't enabled. Enable it in System Settings to use this model." | **Open Settings** link |
| `.unavailable(.modelNotReady)` | "Not available yet, but we're watching for it. Watch download progress in System Settings." | **Open Settings** link |
| `.unavailable(.deviceNotEligible)` | "This Mac doesn't support Apple Intelligence." | blocked, not selectable |
| `.unavailable(_)` (unknown) | "Apple Intelligence isn't available on this Mac." | blocked, not selectable |

The last row matters: `UnavailableReason` is not frozen, so a future macOS can add a
case. The `default` branch must produce sane copy rather than crashing or showing an
empty row.

`ModelBlockedReason` gains cases for these; `.cannotRun` (a RAM verdict) does not fit
and must not be reused.

### 4.3 Availability polling

Availability is **not sticky** — unlike a GGUF on disk, the user can enable or disable
Apple Intelligence at any time, and assets can be evicted.

- **Poll every 5s while the model-selection screen is visible and frontmost.** Stop on
  disappear. `availability` is a cheap local property read, not model IPC, so the cost
  is negligible; the frontmost condition exists so a menu-bar app isn't polling
  forever in the background.
- The poll is a **UI affordance, not the source of truth.** The analysis path
  re-checks availability at run time (§4.7).
- No progress fraction is available in any state. `.modelNotReady` renders an
  indeterminate indicator, never a percentage.

### 4.4 There is no download

There is no API to trigger, cancel, or observe the Apple Intelligence model download.
It happens when the user enables Apple Intelligence in System Settings.

- The Apple row is **not** a download row. It has no progress bar, no size, no Delete.
- `ModelDownloadState` does not apply; the row renders from §4.2's state table.
- The only affordance is the Settings link:

```swift
NSWorkspace.shared.open(
    URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!
)
```

If `open` returns `false` (pane ids have been renamed across releases), degrade to
plain instructional text — never a dead button.

### 4.5 Quality tiers and recommendation

Two independent signals, both read-only — **there is no way to request a better
model.** `SystemLanguageModel` has no `init(variant:)`; you learn what you got.

| Signal | Availability | Use |
|---|---|---|
| `contextSize` | everywhere (back-deployed 26.4) | **the gate** — `>= 8192` required |
| `variant` (`.core3` / `.coreAdvanced3`, `displayName`) | macOS 27+ | display only, appended to row copy |
| OS version | everywhere | fallback signal below 26.4 |

`contextSize` is the primary gate for the reason in §3: it is the number that decides
success, and it's readable everywhere.

**Recommendation tag: the Apple model is never recommended while §4.7's length gate
exists.** `ModelSuitability.recommendedModelID` continues to return a Gemma. For a
meeting recorder, recommending a model that handles the first 20 minutes would be
actively misleading — it is offered as an informed choice, not steered toward. This is
a deliberate answer to the "TBD if we suggest it over Gemma 12B" question in the
overview, and it should be revisited if the length gate is ever removed (§7).

### 4.6 OS gate

FoundationModels is macOS 26.0+; our deployment target is macOS 15.0. Xcode
weak-links a framework whose availability exceeds the deployment target, so Sequoia
still launches — provided no FM symbol is resolved at load time.

- The FM adapter type is `@available(macOS 26, *)`, as is every type storing an FM
  value. FM types never appear in the signature of an always-available type — the
  existing `LLMSession` / `ServiceBackend` protocols are FM-free, so the adapter
  hides behind them without new abstraction.
- `SystemLanguageModel.Variant` needs a nested `macOS 27` guard.
- On macOS 15 the Apple option is **absent from the list entirely**, not
  shown-and-disabled. There is nothing the user can do about it, and a permanently
  greyed row is noise.

**Testing gap:** CI runs on `macos-15`, so it will *build* this correctly but cannot
*run* the app on Sequoia. Launch-on-Sequoia must be a manual test step — a
dyld symbol-not-found at launch breaks the entire app, not just the AI feature, which
makes it the highest-consequence failure mode in this project.

### 4.7 The length gate and fallback

The core behavioral addition. Before an analysis run on the Apple model:

1. Count the assembled prompt's tokens (`SystemLanguageModel.tokenCount(for:)`,
   macOS 26.4+; character-estimate fallback below that).
2. Add the output reserves `ContextSizing` already computes.
3. If the total fits `contextSize`, run normally.
4. If not:
   - **A Gemma model is downloaded** → run the analysis on the best downloaded Gemma
     and surface a non-blocking note: *"This meeting was too long for the Apple model,
     so Gemma 4 12B was used instead."* Silent substitution is not acceptable — the
     user chose a model.
   - **No Gemma is downloaded** → fail with a clear, actionable message:
     *"This meeting is too long for the Apple model. Download Gemma 4 E2B to
     summarize meetings longer than about 20 minutes."*

Truncating the transcript is **explicitly rejected.** A silently partial summary of a
meeting is worse than no summary — the user cannot tell which half they got.

Availability is re-checked at this point too; a model that vanished mid-session takes
the same fallback path.

### 4.8 Library interface: a model reference, not a URL

`LLMService.withConnection(model: URL, backend:, config:)` assumes a file path. The
Apple model has none. `URL` becomes a reference:

```swift
public enum LLMModelRef: Sendable, Equatable {
    case file(URL)        // GGUF on disk — today's behavior
    case appleSystem      // FoundationModels SystemLanguageModel
}
```

This is the "model selection param" from the overview, and it is the right change
regardless of whether the Apple backend ships — it removes an accidental assumption
that the engine is always file-backed.

The wire protocol's `LLMLoadRequest` gains a matching discriminator. `LLMSession`,
`LLMRunning`, `ModelProviding`, and everything in `Intelligence` above them are
unchanged — which is the compatibility outcome the overview asked about.

`reconfigure(contextSize:)` becomes **advisory**: a no-op on the Apple backend, whose
window is fixed. Callers already treat it as best-effort.

### 4.9 Generation options and guardrails

FM offers three knobs. The mapping:

| Ours | FM | Notes |
|---|---|---|
| `temperature` | `temperature` | direct; `0` → `.greedy` |
| `maxTokens` | `maximumResponseTokens` | direct |
| `topK` | `.random(top:seed:)` | mutually exclusive with top-P |
| `topP` | `.random(probabilityThreshold:seed:)` | mutually exclusive with top-K |
| `seed` | carried on `.random(…)` | direct |
| `minP`, `repeatPenalty`, `repeatLastN`, `stopSequences` | — | **unsupported; ignored** |
| `applyChatTemplate: false` | — | **unsupported**; rejected as an error |
| `thinking` | `ContextOptions.ReasoningLevel` (macOS 27) | not used by our analysis |

`MeetingAnalyzer` only sets `maxTokens`, `temperature`, and `thinking: .off`, so the
app path loses nothing. The LocalLLM CLI and the ManualTestApp tab must **disable**
the unsupported controls for this backend rather than accept and silently drop them.

**Guardrails.** Default FM guardrails check both prompt and output and throw
`guardrailViolation`. Real meetings contain profanity, conflict, layoffs, medical and
legal discussion — a false positive means a user's actual meeting silently fails.
Biscotti therefore constructs the model as:

```swift
SystemLanguageModel(guardrails: .permissiveContentTransformations)
```

which skips guardrail checks **for plain string generation** — exactly what our three
tasks produce. This is the correct setting for a private, local meeting recorder
summarizing the user's own conversations. Note it would stop applying if we ever moved
to guided generation, and that the model may still emit a soft refusal ("Sorry, I
can't help with that") as ordinary text, which is not programmatically detectable.

**Streaming.** `ResponseStream` yields **cumulative** snapshots, not deltas. The
adapter diffs consecutive snapshots to produce `StreamEvent.token`.

**Sessions.** An FM session owns its transcript: you create it once with
`instructions:` and send only the new turn. Our `generate(messages:)` re-sends the
whole conversation. The adapter holds one `LanguageModelSession` per `LLMSession` and
treats each `messages` array as a prefix-extension of the last, sending only the tail.
`MeetingAnalyzer` only ever appends, so this holds — but the adapter must **assert**
it rather than assume it, and rebuild the session if the prefix ever diverges.

### 4.10 Error mapping

| FM error | Behavior |
|---|---|
| `exceededContextWindowSize` | should be prevented by §4.7; if reached, same fallback path. The session is dead — rebuild, never retry on it |
| `guardrailViolation` | should not occur under permissive mode; surface as a failed enhancement with the model's reason |
| `refusal` | surface as failed; do not retry |
| `rateLimited` | **[verify]** — thrown for background processes on battery. Biscotti auto-runs analysis after a meeting ends, frequently not frontmost, frequently on battery. If this fires in normal use it is a second blocker. Mitigation if so: use non-streaming `respond` (Apple's own advice), at the cost of the streaming Summary tab |
| `unsupportedLanguageOrLocale` | surface with the language named; check `supportsLocale` up front where possible |
| `assetsUnavailable`, `timeout`, `concurrentRequests` | surface as transient; safe to retry once |

### 4.11 Where the adapter lives

Inside `BiscottiLLM.xpc`, alongside the llama.cpp engine.

FM is a thin client to a system daemon — the weights never enter our process, so the
XPC service's reason for existing (reclaiming multi-GB of RSS on close) doesn't apply
and the hop buys nothing. It is still the right home: one code path, one interface,
one place where `LLMModelRef` is resolved. **[verify]** that
`SystemLanguageModel` reports `.available` from inside an XPC service in a
Developer ID-signed, hardened-runtime, non-sandboxed app.

Touching `Packages/LocalLLM` or `XPCServices/BiscottiLLM` triggers the manual-test
staleness rule in `CLAUDE.md` — `llm_*` steps go back to `not-run`.

---

## 5. Out of scope

- Chunked or rolling-refine long-transcript analysis (§7 — the unblocker, its own
  project).
- Any change to Gemma model behavior, the download flow, or the existing catalog copy.
- Private Cloud Compute, third-party FM providers, tool calling, guided generation,
  multimodal prompts, adapter training.
- Exposing our llama.cpp engine through macOS 27's public `LanguageModel` protocol.
  Technically possible, opposite direction, no user value today.

---

## 6. Planned phases (if unblocked)

Sketch only — architecture was not done, since the project is blocked.

1. `LLMModelRef` + wire discriminator in `LocalLLM`; no behavior change (Gemma-only).
2. FM adapter in `BiscottiLLM.xpc` behind `@available(macOS 26, *)`; CLI + ManualTestApp tab.
3. Availability/quality detection, catalog kind, `ModelProviding` changes.
4. Settings UI: states, copy, polling, Settings link, OS gate.
5. Length gate + fallback in `Intelligence`; new failure copy.
6. Manual test script + hardware pass (§8).

---

## 7. Unblocking conditions

Any **one** of these clears the block:

1. **Long-transcript analysis ships.** A separate project implementing chunked
   analysis. Two variants, analyzed in `research.md` §10:
   - **Rolling refine (recommended)** — walk chunks in order; each fresh session gets
     *(running summary + next chunk)* → updated summary. No reduce step, no
     notes-merging, and streaming survives because the final chunk's call *is* the
     final summary. Recency bias is arguably correct for meetings, where decisions and
     action items cluster at the end. **~60% of the value for ~40% of the effort.**
   - **Full map-reduce** — Apple's TN3193 shape. Better fidelity to early content,
     materially more work, streaming reduced to the final step only.

   Either is a spec project comparable in size to `improve_ai_analysis`. It is **not
   Apple-specific work**: chunking would also let Gemma exceed its 48k ceiling and make
   E2B viable on low-RAM Macs. Three complications, detailed in `research.md` §9:
   speaker ID is inherently global (mitigate by running it on the first chunk and
   extending only while speakers remain unassigned); the user's custom summary prompt
   can only govern the final step; and new progress UI is required.

2. **Apple raises the on-device context window** to roughly 32k. The window doubled
   from 4096 to 8192 in one generation, so this is plausible on a 1–2 year horizon,
   and it would make this spec buildable as written with no chunking at all.

3. **The product decides short meetings are enough** — an explicit choice to ship the
   Apple model for standups and 1:1s, with the length gate as permanent behavior.
   Buildable today. §9 explains why it is not recommended.

---

## 8. Recommendation

**Postpone. Do not build this now, and do not build a reduced version of it.**

The reasoning is about value, not difficulty:

- The Apple model's entire selling point is *"no 3–7 GB download."* But under §4.7,
  long meetings fall back to Gemma — so the user still has to download Gemma, and the
  selling point evaporates for exactly the people it was meant to serve.
- What ships without chunking is: a good option for users whose meetings are mostly
  short, and a faster, lighter default for short meetings when Gemma is already
  installed. Both real, neither worth a project of this size on its own.
- Half of the work (§4.1, §4.2, §4.5, §4.7) exists **only** to manage the limitation.
  It would largely survive unblocking, but it is a poor thing to build first.

**If the goal is specifically "users never have to download a model," then
long-transcript analysis is mandatory and this project is its dependent — commit to
both, or postpone both.** The sequencing in that case is: long-transcript analysis
first (it stands alone and improves Gemma immediately), this project second.

The genuinely cheap piece worth extracting either way is **§4.8's `LLMModelRef`** —
a small, self-contained improvement that removes the "engine is always file-backed"
assumption from `LocalLLM`, and is a prerequisite for any future non-file backend.
It could be lifted into a `/spec task` independent of this project.

---

## 9. Open hardware validations

Unchanged from `research.md` §7; none were run, since the project is blocked before
implementation. Listed here so they travel with the spec:

- [ ] Does `SystemLanguageModel.availability` report `.available` from inside
      `BiscottiLLM.xpc` (Developer ID, hardened runtime, non-sandboxed)?
- [ ] Does `Task` cancellation actually stop an in-flight `respond` / `streamResponse`?
- [ ] Does a menu-bar app running post-meeting analysis hit `rateLimited` on battery?
      (If yes, this is a second, independent blocker — see §4.10.)
- [ ] What does `contextSize` report on the target build, and `variant.displayName`
      on this Mac?
- [ ] Does `permissiveContentTransformations` reliably clear real meeting content, and
      how often do soft refusals appear as ordinary response text?
- [ ] Which `x-apple.systempreferences:` identifier opens the Apple Intelligence pane?
      (Authoritative list is on-device at
      `/System/Applications/System Settings.app/Contents/Resources/Sidebar.plist`.)
- [ ] Does the app launch cleanly on macOS 15 Sequoia with the FM adapter linked?
- [ ] Summary quality on a real meeting vs. Gemma 4 E2B — is the Apple model actually
      competitive at our task?
