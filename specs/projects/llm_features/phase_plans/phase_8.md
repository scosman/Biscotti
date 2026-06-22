---
status: complete
---

# Phase 8: Fix Summary Streaming-to-Final Flash & Scroll Loss

## Overview

When a streamed summary finishes, there is a brief "flash" where the view transits through the empty/Generate state before `load()` repopulates `summaryText`. Additionally, the streaming and final summary use different `documentId` values (`-summary-streaming` vs `-summary`), causing the `MarkdownEditor` to be destroyed and recreated, which loses scroll position.

This phase fixes both issues per `functional_spec.md` section 13.2 and `ui_design.md` section 7.2.

## Steps

### 1. Seed `summaryText` from streaming content before clearing

In `MeetingDetailViewModel.onEnhancementStatusChange(.completed)`, before calling `load()`, capture the current `streamingSummary` value into `summaryText`. This ensures there is never a frame where both `streamingSummary` is nil and `summaryText` is empty (when a summary was just generated).

File: `MeetingDetailViewModel.swift`

```swift
func onEnhancementStatusChange(_ newStatus: EnhancementStatus?) async {
    if newStatus == .completed {
        // Seed summaryText from the final streamed value so the view
        // never flashes through the empty/Generate state between
        // streaming clearing and load() repopulating (§13.2).
        if let streamed = streamingSummary, !streamed.isEmpty {
            summaryText = streamed
        }
        await load()
        await core.reloadSummaries()
    }
}
```

### 2. Unify streaming and final summary into one MarkdownEditor

In `MeetingDetailView.swift`, change the `summaryTabContent` state machine so streaming and has-content states both render through a single `MarkdownEditor` with the same `documentId` (`"<id>-summary"`). The streaming state flips `isEditable: false` and adds the "Generating summary..." header. The `summaryStreamingContent` method receives a non-optional binding/text and uses the shared document ID.

File: `MeetingDetailView.swift`

- Refactor `summaryTabContent` to merge the streaming + has-content branches into a single editor when there is displayable text (either streaming or saved).
- Remove the `-summary-streaming` document ID suffix.
- Set `isEditable: false` during streaming, `true` when final.

### 3. Write tests

File: `SummaryTabTests.swift`

- **Completion path never transits empty state**: Simulate streaming summary -> completion; assert `summaryText` is non-empty after completion even before `load()` finishes.
- **Streaming and final use the same documentId**: The view code uses `"\(meetingID)-summary"` in both streaming and final states (verified by inspecting the view construction; unit test validates the VM state machine -- that when transitioning from streaming to completed, `summaryText` is seeded).

## Tests

- `summaryTextSeededFromStreamingOnCompletion`: When `streamingSummary` has content and status changes to `.completed`, `summaryText` is set to the streamed value before `load()` runs. Verifies no empty-state flash.
- `summaryTextNotOverwrittenWhenNoStreaming`: When there is no `streamingSummary` on completion (e.g. speaker-ID only run), `summaryText` is not clobbered.
- `summaryEditorDocumentIdConsistency`: Verify the document ID used in both streaming and final states is the same (test at the VM level by asserting that the streaming state check uses the same meeting ID pattern).
