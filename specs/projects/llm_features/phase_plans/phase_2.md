---
status: complete
---

# Phase 2: Intelligence Module Core

## Overview

Build the standalone `Intelligence` module inside BiscottiKit. This is the in-process owner of all LLM scenario logic -- orchestration, prompts, parsing, model download state, and LLM abstraction protocols. It compiles and tests with fakes (no real model, no XPC) and has no app wiring yet.

## Steps

1. **Add `LocalLLM` dependency to `BiscottiKit/Package.swift`.**
   - Add `.package(name: "LocalLLM", path: "../LocalLLM")` to the package dependencies.
   - Create the `Intelligence` target with dependencies on `DataStore` and `.product(name: "LocalLLM", package: "LocalLLM")`.
   - Add an `Intelligence` library product.
   - Create the `IntelligenceTests` test target.

2. **Create `EnhancementStatus.swift`** with `EnhancementStatus`, `ModelDownloadState`, and `AISettings` types.

3. **Create `LLMRunning.swift`** with `LLMRunning`, `LLMSession` protocols and `GenerationOptions` convenience extensions (`.speakerID`, `.summary` presets). Also define `StreamEvent` re-export or local typealias as needed.

4. **Create `ModelProviding.swift`** with the `ModelProviding` protocol.

5. **Create `LiveLLMRunning.swift`** with `LiveLLMRunner` (real impl wrapping `LLMService.withConnection`) and `LiveLLMSession` (wrapping `LLMConnection`).

6. **Create `LiveModelProvider.swift`** with `LiveModelProvider` (real impl wrapping `ModelDownloader` + `LocalLLMPaths`).

7. **Create `IntelligencePrompts.swift`** -- Swift-constant prompt catalog: `summarySystem`, `speakerSystem`, `summaryUser(transcript:)`, `speakerUser(transcript:invitees:)`.

8. **Create `TranscriptFormatter.swift`** -- `static func plain(_ transcript: TranscriptData, names: [Int: String]) -> String` producing turn-per-line text.

9. **Create `SpeakerMappingParser.swift`** -- `static func parse(_ raw: String) -> [Int: (name: String, email: String?)]` with defensive line-oriented parsing.

10. **Create `SpeakerIdentifier.swift`** -- speaker-ID step: build prompt -> generate -> parse -> resolve people -> persist assignments. Returns `[Int: String]` name map.

11. **Create `Summarizer.swift`** -- summary step: build prompt -> stream -> accumulate -> persist. Calls `onPartial` for streaming updates.

12. **Create `Intelligence.swift`** -- `@MainActor @Observable` service:
    - `jobs`, `streamingSummary`, `download` observable state.
    - `runAutoEnhancements(meetingID:)` orchestration (single in-flight guard, settings/model gate, speaker-ID then summary in one session, edited-summary guard).
    - `generateSummary(meetingID:transcriptID:force:)` manual path.
    - `isModelDownloaded`, `refreshModelState()`, `downloadModel()`.

13. **Write `IntelligenceTests`** with `FakeLLMRunner`, `FakeSession`, `FakeModelProvider`:
    - Parser tests: well-formed, code-fenced, blank email, extra prose, malformed lines, garbage.
    - TranscriptFormatter tests.
    - Orchestration: gating (both/one/neither toggle, no model), edited-summary guard, ordering (speakers before summary), single session, streaming accumulation, persistence calls, failure -> `.failed`, cancellation.
    - Download state machine: progress -> downloaded, error -> failed.

## Tests

- `SpeakerMappingParserTests`: well-formed lines, code-fenced output, blank email field, extra prose around lines, malformed lines skipped, fully garbage -> empty map, dedupe by index (last wins).
- `TranscriptFormatterTests`: produces correct turn-per-line with names, falls back to speakerLabel when no name, collapses consecutive same-speaker segments.
- `IntelligenceOrchestrationTests`: both toggles on runs speaker-ID then summary in one session; only summarize runs summary only; only speakers runs speaker-ID only; both off is no-op; no model is no-op; edited-summary guard skips summary; streaming accumulation into `streamingSummary`; `.completed` set after success; `.failed` set on error; single in-flight guard; cancellation clears state.
- `IntelligenceDownloadTests`: download progress updates `download` state; successful download transitions to `.downloaded`; failed download transitions to `.failed`; `refreshModelState` reads disk.
- `IntelligencePromptsTests`: system prompts are non-empty; user builders produce expected content.
