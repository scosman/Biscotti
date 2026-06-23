---
status: complete
---

# Functional Spec: Improve AI Analysis

## 1. Summary & Goals

Today the app runs the two LLM tasks per meeting — **speaker-name inference** and
**summary** — as two independent single-turn completions. Each completion re-sends the
full transcript (~20k tokens for a long meeting) and the model re-processes it from
scratch. That's roughly double the prompt-processing work, and the two tasks can't share
any reasoning.

This project replaces those two calls with **one multi-turn "analysis" chat**: a single
conversation that loads the meeting context once and asks the model successive questions
(infer speakers, then summarize, with room for more turns later). The LLM service is
upgraded from a `system + user` pair to a **standard message-list chat format**, and the
service **reuses its KV cache** when a new call extends the previous call's prefix — so
the transcript is processed once and the summary turn starts almost instantly.

Two product gaps are closed along the way:

1. **Double transcript processing** → eliminated by the shared conversation + KV reuse.
2. **No way to (re-)infer speakers on older meetings from the UI** → the existing
   "Regenerate Summary" action now runs the full analysis (speakers *and* summary), so any
   meeting with a transcript can have its speakers inferred on demand.

### Goals

- One analysis conversation covering all per-meeting AI tasks, reusing context across turns.
- LLM XPC service speaks a message-list chat format (system / user / assistant turns).
- LLM service reuses the KV cache when the next call's token prefix matches the last call.
- Richer, shared context for the model: meeting details + human-set speaker mappings +
  transcript, provided once.
- Settings collapse to a single "AI Analysis & Summary" toggle.
- Human-set speaker names are always respected and never overwritten by AI.

### Non-goals (out of scope)

- **AI-generated meeting names.** Designed-for as a *future* turn in the same conversation,
  but not built here.
- **Custom vocabulary** (blocked upstream — see CLAUDE.md).
- **Cross-meeting / cross-session cache warming.** KV reuse only spans turns within one
  analysis session (one connection). Each meeting starts a fresh conversation.
- **New long-transcript truncation strategy.** Context sizing reuses the existing
  count-tokens + reconfigure approach; behavior for transcripts that exceed the model's max
  context is unchanged from today.
- **Streaming the speaker-inference turn.** It stays buffered (we only need the parsed
  result); only the summary turn streams to the UI.

---

## 2. LLM Service: Message-List Chat Format

### 2.1 Decision

The service moves **fully** to a message-list format (confirmed). The legacy
`system: String? + user/prompt: String` shape is removed at every layer — LocalLLM public
API, the XPC protocol/DTOs, `countTokens`, the BiscottiKit `LLMSession`, and the
manual-test app. A single-turn call becomes a one- or two-element message list. There is
one code path.

### 2.2 Message model

A message has a **role** and **text content**:

- Roles: `system`, `user`, `assistant`.
- Content: plain `String` (no multi-part content; no images/tools).

Ordering rules the service relies on (it does **not** need to validate, but app code obeys):

- An optional leading `system` message.
- Then alternating `user` / `assistant` turns.
- The list passed to a generate call ends with a `user` turn (the model is being asked to
  produce the next `assistant` turn).

The Gemma chat template is generalized from single-turn to render an arbitrary ordered list
of these turns (today's `GemmaChatTemplate` renders exactly one system + one user turn;
that is the core thing being extended).

### 2.3 Operations (behavioral contract)

All operations take a **message list** instead of `system` + `user`:

- **Generate (buffered):** messages → final `GenerationResult` (full text).
- **Generate (streaming):** messages → token stream (`.token` / `.reasoningToken` / `.done`),
  unchanged event shape.
- **Count tokens:** messages → token count, used for context sizing.

`GenerationOptions` (maxTokens, temperature, thinking, etc.) and `GenerationResult` keep
their current fields, **plus** the new cache-reuse field below.

### 2.4 Backward behavior parity

Everything that works today on a single-turn prompt must produce equivalent output when
expressed as a one/two-message list (a `system` + a `user`, or just a `user`). This is the
acceptance bar for Phase 1: no behavioral regression, only an API-shape change.

---

## 3. LLM Service: KV-Cache Prefix Reuse

### 3.1 Behavioral contract

Within a **single connection** (one loaded model instance), consecutive generate calls
reuse the KV cache for the longest matching **token prefix**:

- Call 1: `generate([A, B]) → C`
- Call 2: `generate([A, B, C, D]) → E`
- The tokens for `A, B, C` are already in the KV cache from call 1, so call 2 only processes
  the new tokens (`D`) before generating `E`. The shared prefix is *not* re-decoded.

Reuse is **automatic and transparent** — the client always sends the full message list; the
service detects the matching prefix itself. No session handle, conversation ID, or
"continue" flag is required.

### 3.2 Correctness vs. efficiency

- **Correctness is unconditional.** The service computes the longest common *token* prefix
  between the new rendered prompt and what's currently in the KV cache, keeps that portion,
  discards the rest of the cache, and decodes the remaining new tokens. If the prefix
  diverges earlier than the caller expected (e.g. the re-rendered assistant turn doesn't
  tokenize identically), the result is still correct — only fewer tokens are reused.
- **Efficiency depends on exact prefix reproduction.** To get the intended near-instant
  reuse, the chat-template rendering of a *prior assistant turn* (passed back into the next
  call) must reproduce the same tokens that were originally generated for that turn,
  including turn-delimiter tokens. Ensuring this round-trip fidelity is an explicit
  requirement of the implementation. App code feeds the model's own returned text back
  verbatim as the assistant turn to maximize the match.

### 3.3 Lifetime & scope

- Reuse lives in the engine/context that owns the KV cache, for the lifetime of one
  connection. When the connection closes, the service tears down as it does today (process
  exits to reclaim memory).
- The app's analysis flow performs all turns inside **one** connection/session, so the
  transcript-heavy prefix persists between the speaker turn and the summary turn.
- A different meeting (new connection, different transcript) shares no useful prefix and
  gets no reuse — that's expected and fine.

### 3.4 Observability (verification hook)

`GenerationResult` gains a field reporting **how many prompt tokens were served from the
cache** for that call (e.g. `cachedPromptTokenCount`, alongside the existing
`promptTokenCount`). This is the signal the manual test (and any future telemetry) uses to
prove reuse happened:

- First call of a connection: cached count ≈ 0.
- A follow-up call extending the prefix: cached count ≈ the full prior prefix length.

---

## 4. The App Analysis Conversation

### 4.1 Shape

One conversation per analysis run, built and executed inside a single LLM session:

| # | Role | Content |
|---|------|---------|
| 1 | system | Task framing: "You'll be given a meeting transcript and asked several questions about it across multiple turns (e.g. identify speakers, then summarize). Answer each precisely, following the exact format requested in that turn." |
| 2 | user | `<meeting_details>` + (optional) `<user_speaker_person_mapping>` + `<transcript>` + the **speaker-identification task** + its formatting rules. |
| 3 | assistant | Model's speaker lines (parsed & persisted). **(generated)** |
| 4 | user | The **summary task** + its formatting rules. (Transcript & details already in context.) |
| 5 | assistant | Model's markdown summary (streamed to UI & persisted). **(generated)** |

Turn 3 is produced by a **buffered** generate (`generate([1,2])`). Turn 5 is produced by a
**streaming** generate (`generateStreaming([1,2,3,4])`) so the summary renders live; the
`[1,2,3]` prefix is reused from the KV cache.

### 4.2 User turn 2 (the shared context turn)

Built in this order:

```
<meeting_details>
Title: <meeting title>
Date: <start>–<end>            (formatted; end omitted if unknown)
Location: <location>          (line omitted if absent)
Conference: <platform>        (line omitted if absent)
Invitees:
- <Name> <<email>>            (organizer first, then attendees, deduped; email omitted if blank)
- ...
Description:
<calendar event notes>        (whole "Description:" block omitted if eventNotes is empty)
</meeting_details>

<user_speaker_person_mapping>
<index> | <Full Name> | <email-or-blank>
...
</user_speaker_person_mapping>   (entire block omitted when there are no human-set mappings)

<transcript>
Speaker 0: ...
Speaker 1: ...
</transcript>

<speaker-identification task + formatting rules — see 4.4>
```

Field set in `<meeting_details>` (confirmed): **Title + date/time, Invitees, Calendar
description/agenda, Location / conference platform.** All are already available on
`MeetingDetailData` / `CalendarContextData`; no new data plumbing. A field/line is omitted
when its value is absent or empty (never emit empty labels).

The transcript inside `<transcript>` uses the **diarization labels** ("Speaker 0",
"Speaker 1", …) — *not* resolved names — because that's exactly what the model must map.
The transcript is formatted the same way it is today (consecutive same-speaker segments
collapsed into one labeled turn).

### 4.3 `<user_speaker_person_mapping>` — human-set mappings only

- Contains **only** speaker assignments where `userSet == true` (the human explicitly set
  them). AI-set assignments from a previous run are **not** included.
- Rendered one per line as `<speakerIndex> | <Full Name> | <email-or-blank>`.
- The whole block is omitted when there are no human-set mappings.

### 4.4 Speaker-identification task (in user turn 2)

Mostly the same task as today, re-ordered to sit after the context, with two additions:

- Match diarization speakers (Speaker 0, 1, …) to real people using transcript evidence
  (direct address, self-intros, hand-offs) and the invitee list; prefer invitee matches to
  capture emails; omit speakers that can't be confidently identified.
- **Respect `<user_speaker_person_mapping>`:** those speakers are already correctly
  assigned — do **not** change them. The task is only to assign the **currently unassigned**
  speakers.
- Output format (unchanged, so the existing parser still works): one line per *newly*
  identified speaker, nothing else —
  `<speakerIndex> | <Full Name> | <email-or-blank>`.

The assistant's turn-3 output is parsed by the existing speaker-mapping parser and persisted
(see §5). Parsing/persistence are unchanged except for the protections in §5.

### 4.5 Summary task (in user turn 4)

Same intent and format as today's summary prompt:

- Clear markdown summary of key decisions, discussion topics, and outcomes.
- Ends with a `## Action Items` checklist (`- [ ]`), owners noted when clear.
- Markdown only, no preamble, don't invent content.
- May reference the speaker names identified in the previous turn (they're in context).

Streamed to the Summary tab and persisted as the meeting summary (`editedSummary` reset to
`false`), exactly as today.

### 4.6 Generation parameters

Unchanged per task: speaker turn uses low-temperature, small-budget, thinking off; summary
turn uses its current temperature/maxTokens, thinking off. Context is sized **once** for the
whole conversation (count tokens for system + user1 + a budget for the assistant turns +
user2), reusing the existing count-then-reconfigure mechanism. Counting the transcript once
(instead of once per task) is the core efficiency win.

---

## 5. Speaker-Mapping Protection (never overwrite humans)

Two independent protections, both required:

1. **Prompt-side:** human-set mappings are given to the model in
   `<user_speaker_person_mapping>` with an instruction not to change them and to assign only
   unassigned speakers.
2. **Write-side (authoritative):** when persisting AI results, any speaker whose current
   assignment is `userSet == true` is skipped — even if the model erroneously returns a line
   for it. (This is the *existing* `setSpeakerAssignments` behavior; it is the guarantee, not
   the prompt.)

Net effect on a (re-)run:

- Human-set speakers: untouched.
- Previously AI-set (not human-set) speakers: re-guessed and may change (a regenerate
  refreshes AI guesses).
- Unassigned speakers: filled in when the model is confident.

Manual assignment via the speaker-mapping sheet continues to write `userSet == true`
(unchanged).

---

## 6. Triggering & Gating

### 6.1 Single setting

Replace the two settings (`summarizeTranscripts`, `guessSpeakerNames`) with **one**:

- **Label:** "AI Analysis & Summary"
- **Caption:** "Generate a summary from the transcript, and guess the names of speakers
  from context."
- **Default:** on (matching the other AI defaults).
- Persisted as a single boolean (e.g. `aiAnalysisEnabled`) on the settings model. This is a
  pre-release schema change; the two old fields are removed. Any existing dev data resets to
  default-on (acceptable — no shipped users).
- Disabled in the UI when the model isn't downloaded (as the old toggles were).

### 6.2 Auto-run after transcription

Triggered after transcription completes (initial recording *and* re-transcription), same as
today. With the single toggle on and the model downloaded, it runs the analysis conversation:

- **Speaker turn:** run if at least one transcript speaker is *not* human-set. (On a brand-new
  meeting nothing is human-set, so it runs.) Skipped only when every speaker is already
  human-set.
- **Summary turn:** run unless the summary has been manually edited (`editedSummary == true`),
  preserving the user's edits — same guard as today. When skipped, turn 4/5 simply isn't sent.
- If **both** turns would be skipped, no session is opened.

When the toggle is off, or the model isn't downloaded, auto-run no-ops (as today).

### 6.3 Manual "Regenerate Summary"

The meeting-detail overflow action keeps its label ("Regenerate Summary") but now runs the
**full analysis** (both speaker inference and summary):

- Availability is unchanged: enabled when a transcript exists and the model is available. It
  is **not** gated by the AI-analysis toggle — the toggle governs *automatic* behavior;
  pressing the button is explicit user intent and always works (model permitting).
- If the summary was manually edited, the existing confirm dialog appears first; on confirm,
  the summary turn runs (force) and overwrites.
- The speaker turn still only fills non-human-set speakers (§5).

This is what closes the "no way to infer speakers on older meetings" gap: open any older
meeting and hit Regenerate.

---

## 7. UI Changes

### 7.1 Settings

- Remove the two toggles ("Summarize Transcripts", "Guess Speaker Names") and their
  bindings/view-model setters.
- Add the single "AI Analysis & Summary" toggle (§6.1).

### 7.2 Meeting detail — progress pipeline

Keep **two distinct stages** (confirmed): "Identifying speakers" → "Summarizing", reflecting
the two real turns and giving feedback during the long summary stream. Gating updates to the
single toggle:

- "Identifying speakers" shown while/if the speaker turn runs (toggle on or manual
  regenerate; model available).
- "Summarizing" shown while/if the summary turn runs (same conditions; hidden on auto-run
  when `editedSummary`).

The underlying status enum keeps its `identifyingSpeakers` and `summarizing` states.

### 7.3 Meeting detail — Summary tab & speakers

- Summary tab behavior (streaming render, edit, empty-state, "Generate Summary" button)
  unchanged, except empty-state hints now reference the single setting.
- Speaker-name display and the speaker-mapping sheet/popover are unchanged.

---

## 8. Manual-Test App Updates

The Local LLM tab must verify each service change (per project requirement). Because
`Packages/LocalLLM` and `XPCServices/BiscottiLLM` change, all `llm_*` recordable steps are
marked **not-run** and a human re-runs them on hardware (per the staleness rule).

Per phase:

- **Phase 1 (message-list API):** existing inference steps re-wired to the message-list API
  (single-turn = a one-element user list). Add a step exercising a multi-message call
  (system + user) to confirm system framing still works. Existing `llm_*` steps → not-run.
- **Phase 2 (KV reuse):** add a step that, **within one connection**, runs two sequential
  generates where the second's messages extend the first's
  (`[A,B] → C`, then `[A,B,C,D] → E`), and reports the new `cachedPromptTokenCount` plus
  prompt-processing latency for each. A human-question confirms the second call reused the
  bulk of the prefix (high cached count) and was visibly faster. An instruction step explains
  what to look for.
- **Phase 3 (app integration):** optionally, an end-to-end step running the full analysis
  conversation over the sample transcript (speakers then summary), confirming both are
  coherent and the summary turn was fast (prefix reused). (Can also be validated via the real
  app.)

---

## 8.5 Unit-Test Requirements (package-level)

The conditional logic introduced here is not "obvious," so it must be covered by
`swift test` (package) unit tests, not just the manual hardware pass:

- **Conversation / prompt builder:** field omission in `<meeting_details>` (absent/empty
  title, end date, location, conference, description), `<user_speaker_person_mapping>` block
  rendered only for human-set entries (and omitted entirely when none), transcript rendered
  with diarization labels, and the overall turn ordering/structure.
- **Gating decisions:** speaker turn skipped iff every transcript speaker is human-set;
  summary turn skipped iff `editedSummary` (auto-run) and forced on manual regenerate;
  no-session-opened when both turns are skipped; manual regenerate not gated by the toggle.
- **Write-side protection:** AI results never overwrite a `userSet == true` assignment
  (covering the case where the model erroneously returns a line for a human-set speaker).

These run under the gating `make test` target.

## 9. Edge Cases & Error Handling

- **Model not downloaded:** auto-run no-ops; "Regenerate Summary" disabled; settings toggle
  disabled. (Unchanged.)
- **Empty / very short transcript:** analysis still runs; the model may return no speaker
  lines and/or a minimal summary. No special-casing.
- **Speaker turn returns malformed/empty output:** parser yields no assignments; nothing is
  persisted for speakers; the summary turn still proceeds.
- **Model returns a line for a human-set speaker:** ignored by the write path (§5).
- **All speakers already human-set:** speaker turn skipped on auto-run; summary still runs
  (unless edited).
- **Summary already manually edited:** auto-run skips the summary turn; manual regenerate
  confirms then overwrites.
- **Concurrent runs / re-record mid-analysis:** existing single-flight guard
  (one in-flight analysis per app) and existing cancellation/partial-stream handling apply
  unchanged.
- **Transcript + conversation exceeds model context:** existing count-tokens/reconfigure
  behavior; no new truncation. (Known limitation, unchanged from today.)
- **KV prefix mismatch:** correctness preserved by re-decoding the divergent suffix; only
  reuse efficiency is reduced (§3.2).
- **XPC service teardown:** unchanged — the service exits and reclaims memory after the
  connection closes; both turns occur inside one connection so the cache survives between
  them.

---

## 10. Acceptance Criteria

1. The LLM XPC service and LocalLLM API accept a message list (system/user/assistant) at
   every layer; single-turn calls expressed as a short list produce output equivalent to
   today's `system+user` calls (no regression). Verified in the manual-test app.
2. Within one connection, a call that extends the previous call's prefix reuses the KV cache:
   `GenerationResult.cachedPromptTokenCount` reflects the reused prefix and the follow-up
   call's prompt processing is materially faster. Verified in the manual-test app.
3. After recording, AI analysis runs as a single multi-turn conversation that processes the
   transcript once, infers speakers, then summarizes — with the summary turn reusing the
   transcript prefix.
4. "Regenerate Summary" on any meeting with a transcript runs both speaker inference and
   summary; this provides a UI path to infer speakers on older meetings.
5. Human-set speaker names are passed to the model as context and are never overwritten by AI
   guesses.
6. Settings show exactly one "AI Analysis & Summary" toggle (default on), and the meeting
   pipeline shows the two stages (speakers → summary) under that single setting.
7. `make ci` (lint + test + build) is green; the LLM manual-test steps are marked not-run for
   a human hardware pass.

## 11. Title Generation (Phase 5)

### 11.1 What it does

Generates a short, human-readable title for a meeting as a **third turn** of the same analysis
conversation (speaker inference → summary → **title**). Because the transcript, the resolved
speaker names, and the generated summary are already in context, the title turn is a tiny
incremental generation (a handful of tokens) that benefits from everything inferred before it.

### 11.2 When it runs (gating) — strict, non-destructive

Title generation runs **only** when the meeting still carries the system default title and the
user has not renamed it. Concretely, `doTitle` is true **iff both**:

- `meeting.title == <the default-title constant>` — the canonical "Untitled Meeting" string the
  app assigns to a new recording. **Use the existing constant, not a hand-typed literal** (today
  it is `RecordingController.autoTitle()`; this project promotes it to a shared constant so the
  Intelligence layer and the DataStore guard reference the same source of truth). Note the
  stored value is `"Untitled Meeting"` (capital M) — distinct from the lowercase UI
  placeholders; the check must use the real stored default.
- `meeting.editedTitle == false` — the user has not manually renamed the meeting (mirrors the
  `editedSummary` flag that already exists for summaries).

It therefore **never** replaces:
- a title that came from a calendar event (calendar association already set a non-default title,
  so the equality check fails), or
- a user-edited title (`editedTitle == true`).

`doTitle` is **independent of `force`** (unlike `doSummary`). `force` exists to let a manual
regenerate overwrite an *edited summary*; titles have a stricter rule — a non-default or
user-edited title is never touched, even on a forced manual run. There is **no** "regenerate
title" control; title generation only ever rides along with an analysis run.

### 11.3 Where it runs

In the shared analysis session, so it applies to **both** triggers:
- **Auto-run after transcription** — gated by the single AI toggle (`aiAnalysisEnabled`) like the
  rest of the analysis; the title turn runs when `doTitle` holds.
- **Manual "Regenerate Summary"** — not gated by the toggle (explicit intent); the title turn
  runs when `doTitle` holds.

If `doTitle` is false, the title turn is skipped entirely (no wasted generation).

### 11.4 The turn (conversation shape)

The title turn is appended after whatever earlier turns ran, reusing the context:
- If a prior turn ran (speakers and/or summary), the transcript is already in context, so the
  title turn is a lean follow-up user message: just the title instruction.
- If **no** prior turn ran (e.g. all speakers human-set **and** the summary was user-edited, yet
  the meeting is still "Untitled Meeting"), the title turn becomes the first turn and includes
  the meeting details + transcript, then the title instruction.

Generation is **buffered** (not streamed — the title is short and has no live-typing UI), with a
small token budget. The model is asked for a concise, specific title (a few words), output as a
single bare line with no quotes, label, or trailing punctuation.

### 11.5 Persistence — it actually updates the title

After the title turn, the cleaned title is written via a DataStore method that **stores an
AI-generated title without marking it user-edited** (`editedTitle` stays `false`, mirroring
`applyGeneratedSummary` leaving `editedSummary == false`). The write is the authoritative
enforcement point: it re-checks the gate (current title == default **and** not user-edited) so a
late change can't cause an overwrite. Leaving `editedTitle == false` means a later calendar
association can still replace an AI title with a real event title — desirable, as a real event
title outranks a guess. Once a (non-default) AI title is stored, a subsequent analysis run sees a
non-default title and will not regenerate it (no churn). An empty/blank cleaned result is not
written.

### 11.6 Status

A new `EnhancementStatus.generatingTitle` stage is emitted while the title turn runs (parallel to
`identifyingSpeakers` / `summarizing`), so the UI can show a brief "Generating title…" indicator;
the run then completes as today. The meeting-detail title field already binds to the stored title
and refreshes on completion, so the new title appears with no additional UI wiring.

### 11.7 Acceptance criteria (Phase 5)

1. A meeting whose title is the default "Untitled Meeting" (and not user-edited) gets an
   AI-generated title after analysis (auto-run or manual regenerate); the stored title changes
   and `editedTitle` remains `false`.
2. A meeting with a calendar-derived title or a user-edited title is **never** retitled, including
   on a forced manual regenerate.
3. The title turn reuses the prior conversation context (no second transcript copy) when speakers
   and/or summary ran; it still works (with the transcript) when neither did.
4. `make ci` (lint + test + build) is green; LocalLLM is untouched so the `llm_*` manual-test
   steps are unaffected by this phase.
