---
status: complete
---

# Architecture: Custom Summary Prompt

Single-doc architecture (no component sub-docs): the work is one new dependency-light
UI module plus threading one extra string (the summary instruction) through the existing
analysis path, plus one new persisted setting. Nothing here has the internal complexity to
warrant its own component doc.

The change has three layers:

1. **Data** — persist a global `summaryPrompt`; resolve empty → built-in default.
2. **Generation** — make the summary instruction a parameter (default = today's text);
   thread it through context-sizing + `MeetingAnalyzer`; support a per-run override and a
   "mark result as owned" flag.
3. **UI** — a new reusable `SummaryPromptSheet` (its own module), wired into Settings
   (global) and Meeting detail (per-meeting).

---

## 1. Data layer

### 1.1 `AppSettings` (SwiftData `@Model`, DataStore)
Add one stored property (additive, default `""`), alongside `aiAnalysisEnabled` /
`selectedModelID`:

```swift
/// User's custom meeting-summary instruction prompt. Empty means "use the
/// built-in default" (so the shipped default can evolve for non-customizers).
public var summaryPrompt: String = ""
```

Add the matching `init` parameter `summaryPrompt: String = ""`. This stays in
`DataStoreSchemaV1` (the repo keeps all models in V1 pre-release; `selectedModelID` etc.
were added the same way). Adding a property with a default is a lightweight/additive
SwiftData change — no migration plan entry needed. **Confirm** there's no explicit
`VersionedSchema` bump required by the existing setup; if there is, follow that pattern.

### 1.2 `AppSettingsData` (read-model DTO, DataStore)
Add `public let summaryPrompt: String` and populate it in the projection from
`AppSettings`. Pure passthrough (the raw stored value, may be empty).

### 1.3 `applyGeneratedSummary` gains a `markEdited` flag (DataStore+LLMFeatures)
```swift
func applyGeneratedSummary(
    _ markdown: String, for meetingID: UUID, markEdited: Bool = false
) throws {
    …
    meeting.summary = markdown
    meeting.editedSummary = markEdited     // was hard-coded false
    try save()
}
```
Default `false` keeps every existing caller's behavior identical. Only the per-meeting
custom-prompt path passes `true` (see §2.4).

---

## 2. Generation layer (Intelligence)

### 2.1 The default prompt becomes a named constant
In `IntelligencePrompts`, expose the canonical default:

```swift
/// The factory-default summary instruction. Editable copies start from this;
/// an empty stored `summaryPrompt` resolves to this value.
public static let defaultSummaryPrompt = summaryTaskInstructions
```

Keep `summaryTaskInstructions` (internal/tests) as the literal; `defaultSummaryPrompt` is
the public name the app/UI use. Value is unchanged → **default output is byte-identical**.

### 2.2 Make the summary instruction a parameter
The summary instruction is currently hard-coded at two sites. Parameterize them:

- `summaryOnlyFirstUser(detail:transcriptNamed:summaryInstructions:)` — new last arg,
  default `defaultSummaryPrompt`; appends `summaryInstructions` instead of the constant.
- The follow-up turn no longer reads the `summaryFollowUpUser` constant; callers pass the
  resolved instruction string. (`summaryFollowUpUser` may be removed or kept as an alias
  of `defaultSummaryPrompt` for tests.)

### 2.3 Thread the instruction through both the sizing builders and the runner
The instruction must be identical in context-sizing and actual generation, so it is
threaded through both paths in `Intelligence`:

- `buildFirstUserContent(…, summaryInstructions:)` → forwards to `summaryOnlyFirstUser`.
- `contextBudgetFollowUps(…, summaryInstructions:)` → uses `summaryInstructions` where it
  currently uses `summaryFollowUpUser`.
- `MeetingAnalyzer.Context` gains `summaryInstructions: String` and
  `markSummaryEdited: Bool`. `runSummaryTurn` uses `ctx.summaryInstructions` for both the
  first-user (no prior turn) and follow-up branches, and persists with
  `applyGeneratedSummary(accumulated, for:, markEdited: ctx.markSummaryEdited)`.
- `runAnalysisSession(…)` gains `summaryInstructions: String, markSummaryEdited: Bool` and
  passes them into the sizing builders and the `Context`.

### 2.4 Resolving the instruction + the override / ownership flag

`AISettings` (the Sendable bridge in `EnhancementStatus.swift`) gains the **resolved**
(never-empty) prompt:

```swift
public struct AISettings: Sendable {
    public var enabled: Bool
    public var summaryPrompt: String   // resolved: empty → defaultSummaryPrompt
}
```

`AppCore+Live`'s settings closure resolves it:
```swift
let raw = s?.summaryPrompt ?? ""
let effective = raw.isEmpty ? IntelligencePrompts.defaultSummaryPrompt : raw
return AISettings(enabled: s?.aiAnalysisEnabled ?? true, summaryPrompt: effective)
```

Call sites:
- `runAutoEnhancements`: `summaryInstructions = settings.summaryPrompt`,
  `markSummaryEdited = false`. (Auto output is never "owned".)
- `runAnalysis(meetingID:transcriptID:force:summaryPromptOverride:markResultEdited:)` —
  two new args (defaults `nil` / `false`, so existing callers are unaffected):
  - `let effective = summaryPromptOverride ?? (await settingsProvider()).summaryPrompt`
  - pass `summaryInstructions = effective`, `markSummaryEdited = markResultEdited`.

  (Today `runAnalysis` doesn't read settings; the no-override path now awaits
  `settingsProvider()` once to get the saved prompt — cheap, local.)

---

## 3. AppCore helpers (single source of truth for prompt persistence)

So both host view-models share the clear-to-default rule, add to `AppCore`:

```swift
/// Factory default, surfaced without importing Intelligence in UI modules.
public var defaultSummaryPrompt: String { IntelligencePrompts.defaultSummaryPrompt }

/// Saved prompt resolved to its effective text (empty → default).
public func effectiveSummaryPrompt() async -> String {
    let raw = (try? await store.settings())?.summaryPrompt ?? ""
    return raw.isEmpty ? defaultSummaryPrompt : raw
}

/// Persist with the clear-to-default rule: text == default ⇒ store "".
public func saveSummaryPrompt(_ text: String) async throws {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = (trimmed == defaultSummaryPrompt.trimmingCharacters(in: .whitespacesAndNewlines)) ? "" : text
    try await store.updateSettings { $0.summaryPrompt = value }
}
```

(Comparison is on trimmed text so trailing whitespace doesn't defeat the rule.)

---

## 4. UI: new `SummaryPromptUI` module

A new BiscottiKit module so neither Settings nor Meeting-detail UI has to import the
other. Dependency-light: **DesignSystem** + **MarkdownEditorUI** (for the engine control;
see §4.3). It is *callback-driven* — it does **not** import AppCore/DataStore/Intelligence;
all persistence/generation logic lives in the host view-models.

### 4.1 `SummaryPromptSheet` (View) + `SummaryPromptModel` (`@Observable`)

```swift
public enum SummaryPromptMode {
    case global                                   // Settings
    case perMeeting(reference: MeetingReference,  // title/date/duration for the chip
                    summaryWasEdited: Bool)        // drives the inline replace warning
}

@MainActor @Observable
public final class SummaryPromptModel {
    public var workingText: String
    public let initialText: String                 // for unsaved-changes detection
    public let defaultText: String                 // for Restore / clear-to-default compare
    public let mode: SummaryPromptMode
    public var alsoSaveAsDefault: Bool             // perMeeting only; default false

    // pure helpers (unit-tested):
    var isEmpty: Bool                              // trimmed empty
    var hasUnsavedChanges: Bool                    // workingText != initialText
    var isDefault: Bool                            // trimmed == defaultText trimmed
    func added(_ example: PromptExample) -> Bool   // block already present verbatim
    func append(_ example: PromptExample)          // appends "\n\n"+block if not present
    func restoreDefault()                          // workingText = defaultText
}

public struct SummaryPromptSheet: View {
    public init(
        model: SummaryPromptModel,
        onSave: @escaping (String) -> Void,                 // global
        onRegenerate: @escaping (_ text: String, _ alsoSave: Bool) -> Void, // perMeeting
        onCancel: @escaping () -> Void
    )
}
```

- The sheet renders per the UI design: kicker · `biscottiSerif(27)` title · subtitle
  (+ reference chip in `.perMeeting`) · `PROMPT` label · editor (§4.3) · empty caption ·
  `ADD EXAMPLE` label · chips (`FlowLayout`) · (per-meeting: also-save `Toggle` + replace
  warning) · `Divider` · footer (Restore Default · Cancel · primary).
- Confirmations (`.confirmationDialog`) for Restore (when `!isDefault`) and Cancel
  (when `hasUnsavedChanges`) live in the sheet.
- Primary disabled when `isEmpty`. Primary label/action by mode; on primary, the sheet
  calls `onSave` / `onRegenerate` and the host dismisses.

### 4.2 Example blocks
A static `PromptExample { name: String; block: String }` list lives in `SummaryPromptUI`
(the five blocks from the functional spec). `added`/`append` operate on `workingText`.

### 4.3 The editor — use the engine control directly (NOT our `MarkdownEditor`)
Decision: the prose `MarkdownEditor` wrapper is tuned for page-flush, fits-content,
system-font prose — the opposite of a bounded, field-styled prompt box — so it adds
nothing here. The prompt editor uses the engine's `NativeTextViewWrapper` directly,
reusing only the existing `.biscotti()` **theme colors**, via a small dedicated view kept
in `MarkdownEditorUI` (so all `MarkdownEngine` imports stay in one module):

```swift
// MarkdownEditorUI — sibling to MarkdownEditor, purpose-built for a field/sheet.
public struct MarkdownPromptField: View {   // bounded height + internal scroll
    public init(text: Binding<String>, documentId: String, monospace: Bool = false)
}
```

- Configuration: reuse the `.biscotti()` theme; set a **scrolling/bounded** height behavior
  (not `.fitsContent`) so a long prompt scrolls inside a fixed frame; comfortable insets.
  Optional monospace font (JetBrains Mono) when `monospace == true` (P2 — the engine takes
  a `fontName`; if it cleanly resolves, use it, else fall back to system body).
- **Field chrome** (`.elevatedFill` background, 0.5pt `.cardStroke`, `Tokens.cardRadius`)
  is applied by `SummaryPromptSheet` *around* the editor. Ensure the engine text view's
  background is clear/transparent so the chrome shows; the exact knob (config background vs
  setting the NSTextView background) is a component-local detail to confirm against the
  engine API — **fallback:** if transparency isn't configurable, match the engine
  background color to `.elevatedFill`.
- The coding agent confirms the engine's exact height-behavior case and background control
  when building `MarkdownPromptField`; these are local trivia, not architectural forks.

### 4.4 `MeetingReference`
A tiny Sendable struct (title, date, optional duration) the host builds from
`MeetingDetailData` and passes into `.perMeeting`. Lives in `SummaryPromptUI`.

---

## 5. Wiring the entry points

### 5.1 Settings (Global)
- `SettingsView.aiEnhancementsSection`: add the `Summary Prompt` row (mirrors
  `aiLanguageModelRow`) with a `Customize…` button; `.disabled(!aiAnalysisEnabled)`.
- `.sheet(isPresented: $showSummaryPrompt)` presents `SummaryPromptSheet` with a
  `SummaryPromptModel(mode: .global, initialText: effective, defaultText: core.defaultSummaryPrompt)`.
- `SettingsViewModel` gains: load the effective prompt for the model (it already loads
  `AppSettingsData`; compute effective via `core.defaultSummaryPrompt`), and
  `onSave = { text in Task { try? await core.saveSummaryPrompt(text); reloadSettings() } }`.
  Save failures follow the existing optimistic/revert convention (rare; local store).

### 5.2 Meeting detail (Per-meeting)
- `MeetingDetailViewModel`:
  - Replace the overflow **Regenerate Summary** action: instead of
    `generateSummary()`/`showRegenerateConfirm`, set `showResummarizeSheet = true` and
    prepare a `SummaryPromptModel(mode: .perMeeting(reference, summaryWasEdited: detail.editedSummary), initialText: await core.effectiveSummaryPrompt(), defaultText: core.defaultSummaryPrompt)`.
  - `regenerate(withPrompt text: String, alsoSave: Bool)`:
    ```swift
    let pre = await core.effectiveSummaryPrompt()
    if alsoSave { try? await core.saveSummaryPrompt(text) }
    let markEdited = !alsoSave &&
        text.trimmed != pre.trimmed
    let transcriptID = activeVersionID            // existing accessor
    summaryRegenRequested = true; selectedTab = .summary   // existing regenerate UX
    await core.intelligence.runAnalysis(
        meetingID: meetingID, transcriptID: transcriptID,
        force: true, summaryPromptOverride: text, markResultEdited: markEdited
    )
    ```
  - Remove the now-unused `showRegenerateConfirm` confirm path for regenerate. The
    first-run **Generate Summary** button keeps calling the existing direct
    `runSummary(force:false)` (no sheet; uses the saved prompt).
- `MeetingDetailView`: `.sheet(isPresented: $vm.showResummarizeSheet)` presents
  `SummaryPromptSheet` with `onRegenerate = { text, also in vm.regenerate(withPrompt: text, alsoSave: also) }` (presented like the Speaker mapping sheet).

### 5.3 Package wiring
- Add `SummaryPromptUI` target (+ `SummaryPromptUITests`) to `Packages/BiscottiKit/Package.swift`, deps `DesignSystem`, `MarkdownEditorUI`.
- `SettingsUI` and `MeetingDetailUI` gain a dependency on `SummaryPromptUI`.
- `MarkdownEditorUI` gains the new `MarkdownPromptField` (no new external deps).

---

## 6. Error handling

- **Generation** errors: unchanged — surfaced via the existing Summary-tab
  streaming/progress/`.failed` states after the sheet dismisses. The sheet starts no work
  itself.
- **Persistence** (`saveSummaryPrompt`/`updateSettings`) errors: local SwiftData writes;
  rare. On failure, log and keep the sheet open (don't silently claim success). No new
  error surface beyond a brief inline note if it occurs; mirrors existing settings writes.
- **Empty prompt**: prevented at the UI (primary disabled) — never reaches persistence.

---

## 7. Testing strategy

Headless package tests (the gating `make test`); no model/hardware needed.

- **Default-unchanged guarantee (critical):** assert `defaultSummaryPrompt` equals the
  prior `summaryTaskInstructions` text, and that `summaryOnlyFirstUser(... )` with the
  default arg produces byte-identical output to before.
- **IntelligencePrompts:** `summaryOnlyFirstUser(..., summaryInstructions: custom)` embeds
  `custom`; the follow-up path uses the threaded string.
- **Intelligence (fake `LLMRunning`/`LLMSession`, fake store):**
  - `runAnalysis(summaryPromptOverride: X)` causes the summary turn to use `X`.
  - no override → uses `settingsProvider().summaryPrompt` (resolved).
  - `markResultEdited: true` ⇒ `applyGeneratedSummary(markEdited: true)` ⇒
    `editedSummary == true`; `false` ⇒ `editedSummary == false`.
- **DataStore:** `AppSettings.summaryPrompt` round-trips; `AppSettingsData` carries it;
  `applyGeneratedSummary(markEdited:)` sets the flag both ways.
- **AppCore:** `saveSummaryPrompt(default)` stores `""` (clear-to-default);
  `saveSummaryPrompt(custom)` stores the literal; `effectiveSummaryPrompt()` resolves
  empty→default and non-empty→literal.
- **SummaryPromptModel (pure logic):** `isEmpty`, `hasUnsavedChanges`, `isDefault`,
  `added`/`append` (no duplicate append; "added" detection), `restoreDefault`.
- **MeetingDetailViewModel:** `regenerate(withPrompt:alsoSave:)` computes `markEdited`
  correctly across the three cases (no-edit / edited+off / edited+on) and calls
  `runAnalysis` with the right override + flag (verify via a fake/spy Intelligence or core).
- **Update existing tests:** every `AISettings(...)` constructor (tests/fakes) now needs
  `summaryPrompt:`; `MeetingAnalyzer.Context(...)` now needs `summaryInstructions:` /
  `markSummaryEdited:`. Provide sensible defaults in test helpers.

`MarkdownPromptField` chrome/scroll/mono is verified by preview + the on-hardware manual
pass (not unit-tested — it's an AppKit text view).

---

## 8. Out of scope / non-goals (reaffirmed)
No template variables, no builder, no multiple presets, no summary history/undo beyond the
existing single `summary` field, no back-fill of existing summaries, no schema migration
work beyond the additive field.
