---
status: complete
---

# Phase 7: Processing-pipeline status control (Summary tab) + remove pill + auto-jump + re-transcribe

## Overview

Implements functional_spec.md Section 13.1 and ui_design.md Section 7.1. Builds a combined pipeline status in MeetingDetailViewModel that merges transcription and intelligence job statuses into an ordered, gated stage model (Transcribing -> Inferring participant names -> Summarizing). Renders with a new `EnhancementPipelineView`. Removes the tab-bar enhancement pill. Adds auto-jump to Summary tab when the pipeline activates. Wires re-transcribe to trigger auto-enhancements afterward.

## Steps

1. **Add `guessSpeakersEnabled` to `MeetingDetailViewModel`** -- load it alongside `summarizeEnabled` from settings during `load()`. Needed for stage gating.

2. **Define `PipelineStage` model** -- an enum with cases `.transcribing`, `.inferringSpeakers`, `.summarizing`, each carrying a `StageState` (done/active/pending). Add a computed `pipelineStages: [PipelineStage]?` on the VM that merges `currentJobStatus` (TranscriptionService) and `enhancementStatus` (Intelligence) into the ordered stage list. Returns `nil` when no pipeline is active. Stage gating rules:
   - "Inferring participant names" shown only when `guessSpeakersEnabled && modelAvailable`
   - "Summarizing" shown only when `summarizeEnabled && modelAvailable && !editedSummary`

3. **Build `EnhancementPipelineView`** in MeetingDetailUI -- a SwiftUI view that takes `[PipelineStage]` and renders done/active/pending rows using checkmark/spinner/dim-circle + label. Uses existing design tokens (`.monoMeta`, `.inkSecondary`, `.inkTertiary`).

4. **Update `summaryTabContent`** -- insert a new branch BEFORE the "no transcript" placeholder: when `pipelineStages` is non-nil, show `EnhancementPipelineView` instead of the other empty states.

5. **Remove `enhancementPill`** from `tabBar` in `MeetingDetailView` -- delete the `if viewModel.isEnhancing { enhancementPill }` block and the `enhancementPill` computed property.

6. **Auto-jump to Summary tab** -- add a `private var hasAutoJumpedForPipeline: Bool` flag on the VM. When `pipelineStages` transitions from nil to non-nil (pipeline becomes active), set `selectedTab = .summary` once. Reset the flag on `load()`.

7. **Wire `reTranscribe` to call `runAutoEnhancements`** -- after `core.transcription.reTranscribe(meetingID:)` and `load()`, fire `core.intelligence.runAutoEnhancements(meetingID:)` in the same task.

## Tests

- `pipelineStages` returns nil when no job is active
- `pipelineStages` shows only Transcribing when transcription active with no model
- `pipelineStages` shows all three stages when model + both toggles on + not edited
- `pipelineStages` omits "Inferring" when `guessSpeakersEnabled` is off
- `pipelineStages` omits "Summarizing" when `editedSummary` is true
- `pipelineStages` stages transition correctly through the pipeline lifecycle
- `enhancementPill` / `isEnhancing` no longer rendered (existing pill test updated)
- Auto-jump sets `selectedTab = .summary` once when pipeline activates
- Auto-jump does not fire again if user switches tab
- `reTranscribe` triggers `runAutoEnhancements` (verified via LLM session count)
