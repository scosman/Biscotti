---
status: complete
---

# Phase 5: Meeting Detail -- Summary Tab

## Overview

Add a new first "Summary" tab to the meeting detail screen. This tab displays AI-generated summaries (streamed live during generation), allows editing with debounced autosave, and shows context-aware empty states. The overflow menu gets a "Regenerate Summary" item with an edited-summary confirmation dialog. A status pill in the tab bar shows when AI enhancements are in progress. The VM observes enhancement completion to reload data.

## Steps

### 1. Add `Intelligence` dependency to MeetingDetailUI

In `Package.swift`, add `"Intelligence"` to the `MeetingDetailUI` target's dependencies array. Also add `"Intelligence"` to the `MeetingDetailUITests` test target's dependencies.

### 2. Add `Tab.summary` as the first case in the Tab enum

In `MeetingDetailViewModel.swift`, change the Tab enum to:
```swift
public enum Tab: String, CaseIterable, Sendable {
    case summary = "Summary"
    case transcript = "Transcript"
    case notes = "Notes"
}
```

Update `selectedTab` default to `.summary`.

### 3. Add summary state and methods to MeetingDetailViewModel

Add properties:
- `summaryText: String` (the saved summary text from detail)
- `editedSummary: Bool` (from detail, whether user has edited)
- `showRegenerateConfirm: Bool = false`
- `summaryAutosaveTask: Task<Void, Never>?`
- `summarizeEnabled: Bool` (from settings, loaded in load())

Add computed properties:
- `enhancementStatus: EnhancementStatus?` (from `core.intelligence.jobs[meetingID]`)
- `streamingSummary: String?` (from `core.intelligence.streamingSummary[meetingID]`)
- `isEnhancing: Bool` (status is identifyingSpeakers or summarizing)
- `modelAvailable: Bool` (from `core.intelligence.isModelDownloaded`)
- `canRegenerateSummary: Bool` (hasTranscript && modelAvailable)

Add methods:
- `updateSummary(_ text: String)` -- debounced autosave mirroring updateNotes
- `flushSummary() async` -- immediate save, called from onDisappear
- `generateSummary()` -- checks editedSummary, shows confirm or runs directly
- `confirmRegenerate()` -- runs summary with force:true
- `runSummary(force: Bool)` -- calls core.intelligence.generateSummary

### 4. Update `load()` to populate summary state

Set `summaryText`, `editedSummary` from `detail`, and read `summarizeEnabled` from settings.

### 5. Add enhancement status observation

Add `.onChange(of: enhancementStatus)` to the view that on `.completed` reloads data and summaries. Extend `flushNotes` to also flush summary.

### 6. Copy support for summary tab

Extend `canCopy` and the copy action in the tab bar to handle `.summary` case (copy markdown source). Add `copySummary()` method.

### 7. Build `summaryTabContent` view

Decision order:
1. Streaming: read-only MarkdownEditor with "Generating summary..." header
2. Error: Banner + any existing summary below
3. Has content: editable MarkdownEditor with debounce
4. Empty + no transcript: muted placeholder
5. Empty + model available: "Generate Summary" button
6. Empty + no model or feature off: hint + "Open Settings" button

### 8. Add "Regenerate Summary" to overflow menu

Add the menu item gated on `canRegenerateSummary`, disabled while `isEnhancing`. Add confirmation dialog for edited summaries.

### 9. Add status pill to tab bar

Show enhancement status pill (spinner + text) when enhancing.

### 10. Switch selectedTab to .summary on Generate/Regenerate

When the user triggers generate/regenerate, auto-switch to the Summary tab.

## Tests

- `summaryTabInitialState`: verify summaryText/editedSummary populated from detail on load
- `summaryTabStreamingState`: verify streamingSummary is surfaced when present
- `summaryTabEmptyNoTranscript`: verify correct state when no transcript
- `summaryTabEmptyModelAvailable`: verify generate button state
- `summaryTabEmptyNoModel`: verify settings hint state
- `summaryTabEmptyFeatureOff`: verify settings hint when summarize disabled
- `regenerateGatingEditedSummary`: confirm dialog shown when editedSummary is true
- `regenerateNoConfirmWhenNotEdited`: no dialog when editedSummary is false
- `pillVisibility`: enhancementStatus drives pill visibility
- `copySummary`: verify summary text copied
- `summaryAutosaveDebounce`: verify debounced save behavior
- `tabEnumOrder`: verify Summary is first in allCases
