---
status: complete
---

# Component: UI Integration (MeetingDetailUI + SettingsUI)

Internals of the UI changes. Public/structural context is in `architecture.md` §4.3–4.4 and `ui_design.md`. All visuals reuse `DesignSystem` (`Tokens`, `MarkdownEditor`, `Banner`, `StatusRow`, sheet pattern).

---

## A. MeetingDetailUI

### A1. Tab enum + content
`MeetingDetailViewModel.Tab` gains `case summary = "Summary"` **declared first** (so `allCases` → Summary | Transcript | Notes). Update every exhaustive switch:
- `MeetingDetailView.tabContent(fill:)` → add `case .summary: summaryTabContent(fill:)`.
- `canCopy` → add `case .summary: !viewModel.summaryText.isEmpty` (copies markdown source).
- tab-bar Copy action → copy summary on `.summary`.
- `versionPicker` visibility is unchanged (transcript only).

### A2. `MeetingDetailViewModel` additions
State:
```swift
var summaryText: String                 // current saved summary (from detail)
var editedSummary: Bool                  // from detail
var showRegenerateConfirm: Bool = false
private var summaryAutosaveTask: Task<Void, Never>?
// derived
var enhancementStatus: EnhancementStatus? { core.intelligence.jobs[meetingID] }
var streamingSummary: String? { core.intelligence.streamingSummary[meetingID] }
var isEnhancing: Bool { enhancementStatus == .identifyingSpeakers || enhancementStatus == .summarizing }
var modelAvailable: Bool { core.intelligence.isModelDownloaded }
var summarizeEnabled: Bool   // from settings snapshot loaded in load()
```
`load()` also sets `summaryText`/`editedSummary` from `detail`, and reads the two AI settings (for empty-state gating). Observe enhancement completion like transcription: extend the existing `.onChange(of: currentJobStatus)` pattern with `.onChange(of: enhancementStatus)` → on `.completed`, `await load()` (pick up persisted summary + names) and `core.reloadSummaries()`.

Methods:
```swift
func updateSummary(_ text: String)       // user edit: set summaryText; debounce -> store.setSummary (editedSummary=true)
func flushSummary() async                 // onDisappear, mirrors flushNotes
func generateSummary()                    // empty-state button / menu; if editedSummary -> showRegenerateConfirm else run
func confirmRegenerate()                  // dialog "Replace" -> run(force:true)
private func runSummary(force: Bool)      // Task { await core.intelligence.generateSummary(meetingID:, transcriptID: activeVersionID!, force:) }
```
- `updateSummary` mirrors `updateNotes` (1s debounce + autosave) and flips `editedSummary` true via `store.setSummary`.
- Guard: while `isEnhancing`, the editor is read-only and Generate/Regenerate disabled.

### A3. Summary tab view (`summaryTabContent`)
Decision order:
1. `streamingSummary != nil` → render that markdown read-only (`MarkdownEditor(isEditable:false)`), subtle "Generating summary…" header (StatusRow-style).
2. `enhancementStatus == .failed` → `Banner(.error, "Retry")` (Retry → `runSummary(force:true)`), with any existing `summaryText` editor below.
3. `!summaryText.isEmpty` → editable `MarkdownEditor(text: bindingTo(updateSummary), documentId: "<id>-summary")`.
4. empty + `detail.preferredTranscript == nil` → muted "No transcript yet" placeholder.
5. empty + `modelAvailable && summarizeEnabled-or-not` → centered **Generate Summary** button (enabled when a transcript exists; disabled while `isEnhancing`).
6. empty + (`!modelAvailable` or feature off) → centered hint + **Open Settings** button (`core.showSettings()`), text per `ui_design.md` §1d.

### A4. Overflow menu
Add under "Re-transcribe", gated `viewModel.canRegenerateSummary` (`hasTranscript && modelAvailable`):
```swift
Button { viewModel.generateSummary() } label: { Label("Regenerate Summary", systemImage: "sparkles") }
    .disabled(viewModel.isEnhancing)
```
Confirm dialog on the view (like the delete one):
```swift
.confirmationDialog("Replace your edited summary?", isPresented: $viewModel.showRegenerateConfirm, titleVisibility: .visible) {
    Button("Replace", role: .destructive) { viewModel.confirmRegenerate() }
    Button("Cancel", role: .cancel) {}
} message: { Text("This overwrites the summary you edited with a new AI-generated one.") }
```
Tapping Generate/Regenerate also switches `selectedTab = .summary`.

### A5. Transcript: speaker names + clickable
- **Rendering:** `TranscriptContent.attributedString(...)` gains a `names: [Int: String]` param (from `displayedTranscript.speakerAssignments.mapValues(\.name)`). Per segment, the speaker span shows `names[seg.speakerID] ?? seg.speakerLabel`. **Color stays keyed on `seg.speakerID`** (fallback to label hash when `speakerID == nil`). The cache key (`CachedTranscriptKey`) must include the names map so the cache rebuilds when assignments change.
- **Clickable:** add `SpeakerLink` (mirrors `SeekLink`): encode `biscotti://speaker?id=<speakerID>` as a `.link` on each speaker span. `SelectableTranscriptView`'s `OpenURLAction` checks `SpeakerLink.speakerID(from:)` first → `onSpeaker(id)` (`.handled`), else falls back to `SeekLink`. The VM exposes `func openSpeakerSheet(speakerID: Int)` → sets sheet state.
- Segments with `speakerID == nil` (no diarization match) are not clickable (or map to a generic row) — they cannot be assigned.

### A6. `SpeakerMappingSheet` (new, in MeetingDetailUI or DesignSystem)
Presented via `.sheet(item: $viewModel.speakerSheet)` where `speakerSheet` identifies the displayed transcript. Inputs (all `Sendable` DTOs, assembled by the VM):
```swift
struct SpeakerRow: Identifiable { let speakerID: Int; let label: String; let colorSeed: Int; let assigned: PersonData? }
struct SpeakerSheetData { let transcriptID: UUID; let rows: [SpeakerRow]; let invitees: [PersonData]; let people: [PersonData] }
```
- VM builds `rows` from `displayedTranscript` (distinct `speakerID`s present), `invitees` from `detail.calendar` (organizer + attendees), `people` from `core.store.allPersonData()` (deduped against invitees by id/email).
- Each row: color dot + "Speaker N" + a `Menu` picker: **Invitees** section, **People** section, **Add person…** (inline `TextField` → `assignNewPerson(name:)`), **Unassigned**.
- Actions call the VM, which calls `store.setSpeakerAssignment(speakerID:personID:for:transcriptID)` (personID nil for Unassigned; `findOrCreatePerson(name:,email:nil)` for add-new), then `await load()` to re-resolve and re-render. Apply-on-change; **Done** dismisses.
- Works with `modelAvailable == false` (pure manual).

### A7. Status pill (tab bar)
In `tabBar`, trailing (after the version picker / before/with Copy):
```swift
if let status = viewModel.enhancementStatus, viewModel.isEnhancing {
    HStack(spacing: Tokens.spacingXS) {
        ProgressView().controlSize(.small)
        Text(status == .identifyingSpeakers ? "Identifying speakers…" : "Summarizing…")
            .font(.monoMeta).foregroundStyle(.inkSecondary)
    }
}
```
Disappears on `.completed`/`.failed`. Speaker labels are untouched during the run (names appear only after `load()` on `.completed`).

---

## B. SettingsUI — "AI Enhancements"

### B1. `SettingsViewModel` additions
```swift
public private(set) var summarizeTranscripts: Bool = true
public private(set) var guessSpeakerNames: Bool = true
var modelDownload: ModelDownloadState { core.intelligence.download }   // observed
var modelAvailable: Bool { core.intelligence.isModelDownloaded }

func setSummarizeTranscripts(_ on: Bool) async   // optimistic + store.updateSettings; revert on failure
func setGuessSpeakerNames(_ on: Bool) async
func startModelDownload()                          // Task { await core.intelligence.downloadModel() }
```
`load()` reads the two new fields from `store.settings()` and calls `core.intelligence.refreshModelState()`.

### B2. Section view (`SettingsView.aiEnhancementsSection`)
Placed after `generalSection`. Standard `Section` with header "AI Enhancements" + footer/subtitle "AI runs locally on your Mac.", containing:
- Two toggle-with-subtitle rows (existing `VStack(spacing: Tokens.spacingXS){ Toggle(isOn: binding); subtitle }` pattern), bound through `setSummarizeTranscripts`/`setGuessSpeakerNames`. **`.disabled(!viewModel.modelAvailable)`**; when disabled, the bindings read `false` (shown off) regardless of stored value.
- Conditional **download row** when `!modelAvailable`, switching on `modelDownload`:
  - `.notDownloaded`/`.unknown`: text "Download Local Language AI Model?" + subtitle "Several GB · runs entirely on your Mac." + `Button("Download") { viewModel.startModelDownload() }`.
  - `.downloading(f)`: `ProgressView(value: f ?? 0)` (indeterminate when nil) + "Downloading… NN%".
  - `.failed(msg)`: error text + `Button("Retry")`.
  - `.downloaded`: row removed; toggles enable on next observation (no restart).

### B3. Live flip
`core.intelligence.download`/`isModelDownloaded` are `@Observable`; the section recomputes when a download finishes, flipping from the no-model layout to the enabled toggles automatically.

---

## C. Wiring notes
- `MeetingDetailUI` and `SettingsUI` add `Intelligence` as a package dependency (for `EnhancementStatus`/`ModelDownloadState`), exactly as they already depend on `TranscriptionService`/`AppCore`.
- All new state flows through `AppCore.intelligence`; no UI module talks to `LocalLLM` directly.
