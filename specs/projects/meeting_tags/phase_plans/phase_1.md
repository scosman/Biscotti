---
status: complete
---

# Phase 1: Data layer & search

## Overview

Adds the `Tag` SwiftData model, the `Meeting.tags` many-to-many relationship,
schema registration, the `TagData` DTO, DataStore tag CRUD API, tag population
in read models (`MeetingSummary` / `MeetingDetailData`), and search indexing
(`.tags` field at weight 3). No UI changes.

## Steps

1. **Create `Tag` model** (`DataStore/Models/Tag.swift`): `@Model` with `id`,
   `name`, `colorSlot`, `createdAt`, and `@Relationship(inverse:)` back to
   `Meeting.tags`.

2. **Add `tags` relationship to `Meeting`** (`Meeting.swift`): bare
   `@Relationship public var tags: [Tag] = []` (no cascade -- deleting a
   meeting must not delete shared tags).

3. **Register `Tag` in schema** (`DataStoreSchemaV1.swift`): add `Tag.self` to
   the models array.

4. **Create `TagData` DTO** (in `DataStore+ReadModels.swift`): `public struct
   TagData: Sendable, Identifiable, Equatable, Hashable` with `id`, `name`,
   `colorSlot`.

5. **Add `tags: [TagData]` to `MeetingSummary` and `MeetingDetailData`**:
   defaulting to `[]`; populate from `meeting.tags` mapped + alphabetically
   sorted in `meetingSummaries(limit:)` and `meetingDetail(id:)`.

6. **Add DataStore tag API methods** (new file `DataStore+Tags.swift`):
   - `allTags() -> [TagData]`
   - `createTag(name:) -> TagData?`
   - `applyTag(tagID:to:)`
   - `removeTag(tagID:from:)`
   - `createTagAndApply(name:to:) -> TagData?`
   - Test helper: `fetchAllTags() -> [Tag]`

7. **Add `SearchField.tags` case** and wire into `scoreMeeting` (weight 3),
   `fieldSortOrder`, and `matchedFieldsText`.

## Tests

- `TagTests.swift` (DataStoreTests):
  - `roundRobinSlotAssignment`: create 10 tags, verify slots cycle 0..7,0,1
  - `caseInsensitiveDedup`: "Customer" then "customer" -> same id, count 1
  - `trimAndEmptyRejection`: "  " -> nil; " X " -> name "X"
  - `applyIdempotency`: apply twice -> one link
  - `removeKeepsTagInCatalogue`: remove from meeting, tag still in allTags
  - `createTagAndApplyAtomic`: creates + links in one call
  - `deleteMeetingPreservesTags`: delete meeting, tags persist, other meetings keep theirs
  - `summariesCarryTagsAlphabetically`: meetingSummaries includes tags sorted
  - `detailCarriesTagsAlphabetically`: meetingDetail includes tags sorted

- Search tests (in `SearchTests.swift` or new section):
  - `tagOnlyTermMatchesMeeting`: tag-only term -> score 3, matchedFields contains .tags
  - `tagPlusTitleScoring`: both title and tag match -> score 6
  - `matchedFieldsTextIncludesTags`: .tags -> "tags" string

- `TagNameLengthCap` (optional, data layer doesn't enforce -- it's a UI concern)
