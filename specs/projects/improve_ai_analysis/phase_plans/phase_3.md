---
status: complete
---

# Phase 3: App Analysis Integration

## Overview

Replace the two independent single-turn LLM calls (speaker identification + summary) with
a single multi-turn "analysis" conversation that loads meeting context once. This phase
migrates the Intelligence layer's `LLMSession` protocol to the messages API, rewrites
prompts with structured XML sections, introduces `MeetingAnalyzer` as the conversation
orchestrator, collapses `AISettings` to a single `enabled` flag (with an interim bridge
in AppCore), adds `DataStore.humanSetSpeakerMappings`, implements conversation-aware
context sizing, and renames the manual path to `runAnalysis`. `SpeakerIdentifier` and
`Summarizer` are removed.

## Steps

1. **Convert `LLMSession` / `LiveLLMSession` to the messages API.**
   - `LLMRunning.swift`: change `LLMSession.countTokens`, `generate`, `generateStreaming`
     from `(system:user:)` to `(messages: [LLMMessage])`.
   - `LiveLLMRunning.swift`: remove the `buildMessages` bridge in `LiveLLMSession`;
     forward `messages` directly to `connection.*`.
   - Update `reconfigure` (unchanged) and return types (unchanged).

2. **Add `DataStore.humanSetSpeakerMappings(for:)`.**
   - In `DataStore+LLMFeatures.swift`: read `record.speakerAssignments`, filter for
     `userSet == true`, resolve each `personID` via `fetchPerson`, return `[Int: PersonData]`.
     Throws `notFound` for missing transcript.

3. **Collapse `AISettings` to single `enabled` flag.**
   - `EnhancementStatus.swift`: replace `summarize`/`guessSpeakers` with `enabled: Bool`.
   - `AppCore+Live.swift` interim bridge: `AISettings(enabled: (s?.summarizeTranscripts ?? true) || (s?.guessSpeakerNames ?? true))`.

4. **Rewrite `IntelligencePrompts`.**
   - Replace old `summarySystem`/`summaryUser`/`speakerSystem`/`speakerUser` with:
     `analysisSystem`, `meetingDetailsBlock(_:)`, `userSpeakerMappingBlock(_:)`,
     `speakerTaskInstructions`, `summaryTaskInstructions`,
     `analysisFirstUser(detail:human:transcriptSpeakerLabeled:)`,
     `summaryOnlyFirstUser(detail:transcriptNamed:)`, `summaryFollowUpUser`.

5. **Add `MeetingAnalyzer`.**
   - New file `MeetingAnalyzer.swift` with `Context` struct and `run(_:_:)` method.
   - Handles cases: both (multi-turn), speakers-only, summary-only.
   - Reuses `SpeakerMappingParser` for parse, `TranscriptFormatter` for formatting.
   - `persistSpeakers`: parse -> findOrCreatePerson -> setSpeakerAssignments.
   - `streamAndPersistSummary`: streaming accumulation + applyGeneratedSummary.

6. **Update `ContextSizing` to conversation-aware sizing.**
   - Add `contextSizeForAnalysis(firstUser:system:followUpUser:assistantReserveTokens:session:)`.
   - Remove old `contextSize(forPairs:session:)` and `contextSize(forSystem:user:session:)`.

7. **Rewire `Intelligence`.**
   - `runAutoEnhancements`: use shared gating helper (`doSpeakers` iff >= 1
     non-human-set speaker; `doSummary` iff `!editedSummary`). Guard on `settings.enabled`.
     Call `MeetingAnalyzer.run` inside one `withSession(.modelOnly)`.
   - Rename `generateSummary` to `runAnalysis(meetingID:transcriptID:force:)`.
     Not gated by settings. `doSpeakers` per helper; `doSummary` from `editedSummary`/`force`.
   - Remove `buildPromptPairs` and `extractInvitees` (logic moves to MeetingAnalyzer context).

8. **Remove `SpeakerIdentifier` and `Summarizer`.**

9. **Update `MeetingDetailViewModel` call site.**
   - `runSummary(force:)` calls `core.intelligence.runAnalysis(...)` instead of
     `core.intelligence.generateSummary(...)`.

10. **Update all test fakes and tests.**
    - `FakeSession` / `MockCountingSession` -> messages API.
    - Rewrite Intelligence orchestration tests for new gating logic and `MeetingAnalyzer`.
    - Add prompt builder tests, gating truth table, `humanSetSpeakerMappings` test.

## Tests

- `IntelligencePrompts` tests: `analysisSystem` non-empty; `meetingDetailsBlock` field
  omission (no title, no end, no location, no conference, no notes, full fields);
  `userSpeakerMappingBlock` with entries and empty; `analysisFirstUser` includes transcript
  with Speaker-N labels + speaker task; `summaryOnlyFirstUser` includes named transcript +
  summary task; `summaryFollowUpUser` is summary instructions only.
- Gating truth table: `doSpeakers` iff >= 1 non-human-set; auto `doSummary` = `!editedSummary`;
  no session when both false; manual `runAnalysis` ignores `settings.enabled`.
- `MeetingAnalyzer` message sequencing: fake session records per-call messages; turn-1 =
  `[system, user1]`; turn-2 = `[system, user1, assistant1, user2]` with assistant1 = model
  verbatim; case-C single-turn summary-only; speakers persisted; summary persisted.
- `humanSetSpeakerMappings`: returns only human-set, drops dangling, empty when none,
  throws for missing transcript.
- Context sizing: `contextSizeForAnalysis` tests.
