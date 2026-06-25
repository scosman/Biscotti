---
status: complete
---

# Architecture: Meeting Tags

Single-file architecture (small/medium project; no `/components` docs). All logic lives in
`BiscottiKit` packages so it runs under `swift test`. References to existing code are
`file:line` from the repo.

Module placement:

- **DataStore** — `Tag` model, `Meeting.tags`, schema registration, tag API, `TagData`
  DTO, read-model + search changes.
- **DesignSystem** — tag-dot palette, `TagPill`, `FlowLayout`.
- **MeetingListUI** — compact tag line in the row.
- **MeetingDetailUI** — `TagAddButton`, `TagPickerPopover`, pure picker-result fn, view-model
  wiring, tags row in `chrome`.

---

## 1 · Data model

### Tag entity (new) — `DataStore/Models/Tag.swift`

Mirrors the `Person` shared-entity / many-to-many pattern (`Person.swift:16-20`).

```swift
@Model
public final class Tag {
    public var id: UUID
    public var name: String          // trimmed, case-insensitively unique
    public var colorSlot: Int        // 0–7, stable palette index (round-robin at creation)
    public var createdAt: Date       // assignment order / tie-break

    @Relationship(inverse: \Meeting.tags)
    public var meetings: [Meeting] = []

    public init(id: UUID = UUID(), name: String, colorSlot: Int, createdAt: Date) { … }
}
```

### Meeting relationship — `Meeting.swift`

Bare `@Relationship` (no cascade — deleting a meeting must NOT delete shared tags), default
empty array (additive):

```swift
@Relationship public var tags: [Tag] = []
```

### Schema registration — `DataStoreSchemaV1.swift:8-19`

Add `Tag.self` to `DataStoreSchemaV1.models`. **Extend V1 directly** (do not introduce V2):
the app is pre-release with no shipped persistent stores, and the V1 list has been grown
incrementally through Stage A. Adding a new entity + a defaulted relationship is a
lightweight, additive change SwiftData handles automatically; the un-wired
`DataStoreMigrationPlan` (`DataStore.swift:52-53`) stays un-wired. (Risk: a developer's
local store auto-migrates; worst case they delete it — acceptable pre-release.)

### Ordering note

SwiftData to-many relationships are unordered, so all tag rendering and DTO population sort
**alphabetically** (`localizedStandardCompare`, case-insensitive). This is the single
behavioural deviation from "order applied" (functional spec §5.1).

---

## 2 · DataStore API (actor methods)

New `TagData` DTO (Sendable, crosses the actor boundary; `@Model Tag` never leaves it):

```swift
public struct TagData: Sendable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public let name: String
    public let colorSlot: Int
}
```

New actor methods (best-effort, non-throwing — same style as `setNotes`):

| Method | Behaviour |
|---|---|
| `allTags() -> [TagData]` | Fetch all `Tag`, sort by name, map to DTO. |
| `createTag(name:) -> TagData?` | Trim; if empty → `nil`. If a tag exists whose name `==` case-insensitively → return it (no dup). Else `colorSlot = currentTagCount % 8`, insert with `createdAt = .now`, save, return DTO. |
| `applyTag(tagID:to:)` | Fetch tag + meeting; append to `meeting.tags` if absent; save. No-op if already applied. |
| `removeTag(tagID:from:)` | Remove tag from `meeting.tags`; save. Never deletes the `Tag`. |
| `createTagAndApply(name:to:) -> TagData?` | Atomic find-or-create (as `createTag`) then apply; returns the tag. Used by the picker "Create" row to avoid a two-round-trip race. |

Round-robin uses `currentTagCount` (a `FetchDescriptor<Tag>` count) at creation time; with no
deletion in V1, count == creation order, so slots cycle `0,1,…,7,0,1,…`.

### Read-model changes — `DataStore+ReadModels.swift`

- Add `tags: [TagData]` to **`MeetingSummary`** (`:7`) and **`MeetingDetailData`** (`:41`),
  each populated from `meeting.tags` mapped + alphabetically sorted in
  `meetingSummaries(limit:)` (`:341`) and `meetingDetail(id:)` (`:379`).

---

## 3 · Search indexing — `DataStore+ReadModels.swift`

- **`SearchField`** enum (`:296`): add `case tags`.
- **`scoreMeeting(_:terms:)`** (`:643-687`): add a block in the `for term in terms` loop,
  parallel to the notes check:

  ```swift
  if meeting.tags.contains(where: {
      $0.name.lowercased().localizedStandardContains(term)
  }) {
      score += 3            // weight 3 — equal to a title match
      fields.insert(.tags)
  }
  ```

- **`fieldSortOrder`** (`:727-734`): give `.tags` an order slot (after `.title`, e.g. value
  reflecting its weight).
- **`matchedFieldsText`** in `MeetingListViewModel.swift:288-299`: add `case .tags: "tags"`.

No changes to AppCore/AppShell/MeetingListView search plumbing — they're generic over
`SearchHit`/`SearchField`. The legacy `search(_:)` (`DataStore+Phase3_2.swift:329`) is left
unchanged (only used by old tests; live path is `searchHits`).

---

## 4 · UI components

### 4.1 Tag-dot palette — `DesignSystem/Color+Theme.swift`

An ordered 8-element palette of adaptive colours via `dynamicColor(light:dark:)` (values in
ui_design.md §6), exposed as:

```swift
public extension Color {
    static let tagSwatches: [Color] = [ … 8 dynamicColor pairs … ]
    static func tagSwatch(slot: Int) -> Color { tagSwatches[((slot % 8) + 8) % 8] }
}
```

Slot 4 (Red) reuses the existing `signalRed` pair. Sage is never in the palette.

### 4.2 `TagPill` — `DesignSystem/TagPill.swift`

`public struct TagPill: View` with a `Size` enum (`.detail` / `.compact`) carrying the
constants from ui_design.md §1. Built like `SourcePill` (HStack: dot circle + `Text`,
`neutralChip` fill, `RoundedRectangle`). Takes `TagData` (uses `colorSlot` →
`Color.tagSwatch(slot:)`). The **detail** size optionally takes an `onRemove: (() -> Void)?`;
when non-nil it renders the hover-✕ (state + opacity per ui_design.md §3). Compact passes
`nil` (display-only).

### 4.3 `FlowLayout` — `DesignSystem/FlowLayout.swift`

A small `Layout`-protocol conformance (none exists in the repo) that lays children
left-to-right and wraps to the next line, with configurable spacing. Used by the detail tags
row. Pure geometry → unit-testable; keep it minimal.

### 4.4 `TagAddButton` — `MeetingDetailUI/TagAddButton.swift`

Ghost pill (detail dimensions) with the three states (has-tags / empty / picker-open) from
ui_design.md §4; dashed border via `strokeBorder(style: StrokeStyle(dash:))`. Hover state via
`@State`. Acts as the popover anchor.

### 4.5 `TagPickerPopover` — `MeetingDetailUI/TagPickerPopover.swift`

Modelled on `PersonPickerPopover` (`SpeakerMappingSheet.swift:179`). Width 260. Search/create
field (auto-focused) → "TAGS" kicker → catalogue rows (dot + name + sage ✓ if applied) →
create row. Keyboard nav (↑/↓/↩/⎋) carried over; **committing a catalogue row toggles and
keeps the popover open** (differs from the person picker, which closes on select).

The filtering/create-visibility logic is a **pure function** (testable, mirrors
`computePersonPickerResult`):

```swift
struct TagPickerResult { let rows: [TagRow]; let createOption: String? }   // TagRow = TagData + isApplied
func computeTagPickerResult(catalogue: [TagData], applied: Set<UUID>, query: String) -> TagPickerResult
```

`createOption` is non-nil iff the trimmed query is non-empty **and** no catalogue tag equals
it case-insensitively. `rows` = catalogue filtered by case-insensitive contains, alphabetical,
each flagged `isApplied`.

---

## 5 · View-model wiring

### Detail — `MeetingDetailViewModel`

- New observable state: `catalogueTags: [TagData]` (loaded via `store.allTags()` on
  `load()`/`refreshData()`), and `appliedTags: [TagData]` derived from
  `MeetingDetailData.tags`.
- New methods (each: call the actor, then `await refreshData()` **and**
  `core.reloadSummaries()` so the list's third line updates):
  - `toggleTag(_ tag: TagData)` → `applyTag`/`removeTag` based on current membership.
  - `createAndApply(_ name: String)` → `store.createTagAndApply(name:to:)`, then refresh
    catalogue + data.
  - `removeTag(_ tag: TagData)` → `store.removeTag`, refresh.
- `@State pickerOpen` lives in the view (same idiom as `openPopoverSpeakerID`).

### List — `MeetingListView.meetingRow` (`:128`)

Add a third `VStack` child after the when-line, rendered only when `meeting.tags` is
non-empty: an `HStack(spacing: 5)` of `.compact` `TagPill`s (first 2 alphabetical) + a
`+N` `Text` in `.monoBadge` when `tags.count > 2`. Reads `MeetingSummary.tags` — no new data
plumbing. Bump the row VStack spacing for tagged rows only so untagged rows keep their height.

### Detail view — `MeetingDetailView.chrome` (`:396`)

Insert the tags row (a `FlowLayout` of detail pills + `TagAddButton`) between `header`
(`:397`) and the calendar card. Existing child spacing (`Tokens.spacingMD`) gives the 16pt
gaps.

---

## 6 · Concurrency & data flow

- `DataStore` stays an actor; only `Sendable` DTOs (`TagData`, updated `MeetingSummary` /
  `MeetingDetailData`) cross to the `@MainActor @Observable` view models. `@Model Tag` never
  leaves the actor.
- Refresh is explicit (repo convention): after any mutation the VM re-fetches and reassigns
  observable state; `core.reloadSummaries()` (`AppCore.swift:601`) repopulates the list.
  No `@Query`.

## 7 · Error handling

Tag operations are best-effort and non-throwing, matching `setNotes`/`setTitle`. Invalid
input (empty-after-trim name) is a silent no-op (`createTag` returns `nil`; the create row
isn't offered for whitespace-only queries anyway). No user-facing error surfaces; failures
are at most logged via existing patterns.

---

## 8 · Testing strategy

**DataStoreTests** (new `TagTests.swift`):

- Round-robin slot assignment: create 10 tags → slots `0,1,…,7,0,1`.
- Case-insensitive dedup: `createTag("Customer")` then `createTag("customer")` → same id,
  catalogue count 1.
- Trim + empty rejection (`"  "` → `nil`; `" X "` → name `"X"`).
- Apply idempotency (apply twice → one link); remove keeps the `Tag` in the catalogue.
- `createTagAndApply` creates + links atomically.
- Delete a meeting → its links drop, tags persist, other meetings keep their tags.
- `meetingSummaries`/`meetingDetail` carry tags, alphabetically sorted.

**Search** (`SearchTests.swift` / `MeetingsSearchTests.swift`):

- Tag-only term matches the meeting with `.tags` field and score 3.
- Title+tag term scoring; `matchedFieldsText` includes "tags".

**UI logic** (`MeetingDetailUITests` or a logic target):

- `computeTagPickerResult`: contains-filter, `isApplied` flags, `createOption` visibility
  (hidden on exact case-insensitive match, shown otherwise, nil for whitespace).

**DesignSystem**: `FlowLayout` geometry (wrap at width); palette has 8 slots and `tagSwatch`
wraps the index. (Adaptive colours are eyeballed on hardware in the final phase, not unit
tested for appearance.)

Optional: `MeetingDetailViewModel` integration test that toggle/create/remove updates
`appliedTags` and triggers a summary reload.

---

## 9 · Risks / mitigations

- **Unordered relationship** → alphabetical sort everywhere (decided).
- **Extending schema V1 in place** → safe pre-release (no shipped stores); documented above.
- **Custom `FlowLayout`** → keep minimal + unit-test geometry; low risk.
- **Dark dot legibility** → proposed dark variants are provisional; the final human phase
  tunes them on real hardware.
- **Per-summary tag load cost** → a cheap relationship read at V1 scale (search already scans
  all meetings).

---

## 10 · Manual-test staleness

No `Packages/Transcription`, `AudioCapture`, or `LocalLLM` (incl. `BiscottiLLM`) code is
touched, so the `ManualTestApp/Results` manual-test gate is unaffected (no `not-run` marking
needed).
