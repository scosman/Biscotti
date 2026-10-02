---
status: complete
---

# Phase 5: LLM Integration and Debug Window

## Overview

Wire voiceprint matching into the Intelligence analysis pipeline, add
the `#if DEBUG` debug window, and update the Makefile for
`IntelligenceAITests`. This phase connects the pure matching logic
(Phase 4) to the LLM prompts so the model receives a
`<voiceprint_matches>` block, and gives the developer a debug window
(right-click a speaker label) to inspect matches.

## Steps

1. **`IntelligencePrompts` changes** (`IntelligencePrompts.swift`):
   - Add `voiceprintBlock: String = ""` parameter to `analysisFirstUser`;
     insert it after the mapping block, before `<transcript>`.
   - Insert voiceprint instruction paragraph into
     `speakerTaskInstructions` (functional spec section 7.3 text).
   - Append `(the person who recorded this meeting)` to the invitee
     with `isCurrentUser == true` in `inviteeBlock`.

2. **`VoiceprintReport.swift`** (new file in Intelligence):
   - `enum VoiceprintReport` with `static func render(...)` producing
     the `<voiceprint_matches>` block text per architecture section 6.2.

3. **`VoiceprintEvidence.swift`** (new file in Intelligence):
   - `VoiceprintEvidenceResult` struct and `VoiceprintEvidence` enum
     with `compute(...)` and `block(...)` per architecture section 6.3.

4. **`Intelligence.swift` + `MeetingAnalyzer.swift` wiring** (section 6.4):
   - In `runAnalysisSession`: compute `voiceprintBlock` once, pass it
     to `buildFirstUserContent` and to `MeetingAnalyzer.Context`
     (new `voiceprintBlock: String` field).
   - `MeetingAnalyzer.runSpeakerTurn` passes `ctx.voiceprintBlock` to
     `analysisFirstUser`.
   - `buildFirstUserContent` passes `voiceprintBlock` to `analysisFirstUser`.

5. **`Intelligence+VoiceprintDebug.swift`** (new file, `#if DEBUG`):
   - `VoiceprintDebugReport` struct and `Intelligence.voiceprintDebug()`
     extension per architecture section 6.5.

6. **`TranscriptListView` context menu** (section 8):
   - Add `onVoiceprintDebug: (Int) -> Void` callback on
     `TranscriptListView` and `TranscriptSegmentRow`.
   - Speaker-label `Button` gets `.contextMenu` with
     "Voiceprint Debug..." (all inside `#if DEBUG`).

7. **`MeetingDetailViewModel` debug support** (section 8):
   - Add `VoiceprintDebugModel`, `voiceprintDebug` property,
     `openVoiceprintDebug(speakerID:)`, `reloadVoiceprintDebug(kind:)`.

8. **`VoiceprintDebugView.swift`** (new file, `#if DEBUG`):
   - Sheet view with kind picker, candidate table, nearest table,
     LLM block text per architecture section 8.

9. **`MeetingDetailView` sheet** (section 8):
   - Wire `.sheet(item: $viewModel.voiceprintDebug)` to
     `VoiceprintDebugView`.

10. **Package.swift dependency update**:
    - Add `VoiceprintMatching` to `Intelligence` target dependencies.
    - Add `VoiceprintMatching` to `IntelligenceTests` dependencies.
    - Add `VoiceprintMatching` to `MeetingDetailUI` if needed for
      `VoiceprintKind` in the debug view (it is in `DataStore`, which
      `MeetingDetailUI` already depends on, so may not be needed).
    - Add `VoiceprintMatching` to `MeetingDetailUITests`.

11. **`Makefile` `test-ai` update**:
    - Add `BISCOTTI_RUN_AI_TESTS=1 swift test --package-path
      Packages/BiscottiKit --filter IntelligenceAITests`.

12. **`IntelligenceAITests` test target** (new, section 10):
    - New `testTarget` in Package.swift with `BISCOTTI_RUN_AI_TESTS`
      env guard. Tests are gated and run via `make test-ai` only.

## Tests

- `VoiceprintReport.render` golden strings: high, medium, low,
  ambiguous (3-way), none (with unnamed), none (no match), no-vector,
  singular/plural, `(not invited)`, each invitee variant, empty history
  returns `""`, assigned persons excluded from invitee part.
- `IntelligencePrompts.analysisFirstUser`: block placement; omitted
  when empty; instruction paragraph present; current-user marker.
- `Intelligence` with `FakeLLMRunner`: speaker turn user message
  contains the voiceprint block from a seeded store;
  context-sizing content equals sent content; store error gives prompt
  without the block.
- `voiceprintDebug` (debug builds): candidates and neighbors for a
  seeded store; user-tagged speaker still gets candidates; no-voiceprint
  speaker gives `hasVoiceprint == false`; kind switch changes space.
- `MeetingDetailViewModel.openVoiceprintDebug` sets
  `voiceprintDebug`; `reloadVoiceprintDebug` replaces report.
