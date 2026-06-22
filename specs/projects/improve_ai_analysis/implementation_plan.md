---
status: complete
---

# Implementation Plan: Improve AI Analysis

Four phases, matching the project's intended sequence (service format → KV reuse → app
integration → settings/UI). Each phase is one coherent, reviewable unit and ends green on
`make ci` (lint + test + build). Details live in `architecture.md` (section refs below);
this is the ordered checklist.

## Phases

- [x] **Phase 1 — LocalLLM message-list format.** Add `LLMMessage`; generalize
  `GemmaChatTemplate` to multi-turn; convert `LLMEngine`, `InferenceEngine`, `ServiceBackend`,
  `InProcessBackend`, `XPCBackend`, `LLMConnection`, and the two request DTOs to a `messages`
  list; update the XPC host (`BiscottiLLM/main.swift`) and `MockEngine`; rewire the
  ManualTestApp `llm_*` call sites to the messages API (single-turn = one user message) and
  add the `llm_chat_system` step; mark `llm_*` steps not-run. **No behavior change** beyond
  shape — single/two-message parity with today. Tests: template parity + multi-turn, DTO
  Codable round-trip, MockEngine connection flow. (Arch §1, §6)

- [x] **Phase 2 — KV-cache prefix reuse.** Add `cachedTokens` state + the diff/`seq_rm`/
  suffix-prefill algorithm in `LLMEngine.runGeneration`; `commonPrefixLength` helper;
  error/cancel + reconfigure/unload reset; add `GenerationResult.cachedPromptTokenCount`; add
  the `#if DEBUG` cached/fresh/generate timing log. Add the `llm_kv_reuse` manual-test step
  (two extending generates in one connection) + a `make test-ai` two-turn reuse assertion;
  mark `llm_*` not-run. Confirm the position-continuation mechanism on hardware (§2.3). Tests:
  `commonPrefixLength` unit; `test-ai` reuse. (Arch §2)

- [x] **Phase 3 — App analysis integration.** Add `DataStore.humanSetSpeakerMappings(for:)`;
  convert `LLMSession`/`LiveLLMSession` to the messages API; rewrite `IntelligencePrompts`
  (analysis system + turn builders with `<meeting_details>` / `<user_speaker_person_mapping>`
  / `<transcript>`); add `MeetingAnalyzer` (remove `SpeakerIdentifier` + `Summarizer`, reuse
  `SpeakerMappingParser` + `TranscriptFormatter`); rewire `Intelligence.runAutoEnhancements`
  and rename the manual path to `runAnalysis(meetingID:transcriptID:force:)` with the gating
  helper; collapse `AISettings` to a single `enabled` (interim `AppCore` mapping from the two
  old fields); conversation-aware `ContextSizing`. Tests: prompt builders, gating truth table,
  `MeetingAnalyzer` message sequencing with a `FakeLLMSession`, `humanSetSpeakerMappings`.
  (Arch §3.1, §4)

- [x] **Phase 4 — Settings & UI cleanup.** Swap the two `AppSettings`/`AppSettingsData`
  bools for `aiAnalysisEnabled` and update `settings()`/`updateSettings()` + the `AppCore`
  closure; SettingsUI single "AI Analysis & Summary" toggle (remove the two); MeetingDetailUI
  — `runSummary(force:)` → `runAnalysis`, keep the "Regenerate Summary" label + edited-summary
  confirm, keep two pipeline stages gated on the single flag, `aiAnalysisEnabled` in the view
  model. Tests: SettingsUI/MeetingDetailUI view-model updates. (Arch §3.2, §5)
