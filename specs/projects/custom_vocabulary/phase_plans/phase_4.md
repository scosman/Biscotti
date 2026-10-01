---
status: complete
---

# Phase 4: Settings Section and Editor Sheet

## Overview

Add the Custom Vocabulary settings section and the vocabulary list editor sheet to
`SettingsUI`. The section sits directly after General and before Permissions, with a
master toggle, a "Vocabulary List" row opening the editor sheet, and a calendar toggle.
Rows 2 and 3 are hidden (not disabled) when the master toggle is off. The editor sheet
follows `SummaryPromptSheet` visual conventions (kicker, serif title, 13pt subtitle).

Inserting "Custom Vocabulary" at `sectionTitles` index 1 shifts every downstream section
index by one. All existing `sectionTitles[N]` references and layout tests are re-indexed.

## Steps

1. **`SettingsViewModel` -- add vocabulary properties and actions.**
   New observable properties: `customVocabularyEnabled: Bool`, `calendarVocabularyEnabled: Bool`,
   `vocabularyTerms: [String]`. New methods: `setCustomVocabularyEnabled(_:)`,
   `setCalendarVocabularyEnabled(_:)`, `addVocabularyTerm(_:) -> VocabularyTermError?`,
   `removeVocabularyTerm(at:)`, `updateVocabularyTerm(at:to:) -> VocabularyTermError?`.
   `load()` reads the three fields from the settings DTO. Each write goes through the
   existing `core.store.updateSettings` path with optimistic update and revert on failure.
   Add `VocabularyTermError` enum (`.duplicate(String)`, `.tooLong`). Remove the TODO comment.

2. **`SettingsView` -- re-index `sectionTitles`.**
   Insert `"Custom Vocabulary"` at index 1. Update all `sectionTitles[N]` references:
   - `permissionsSection`: 1 -> 2
   - `notificationsSection`: 2 -> 3
   - `aiEnhancementsSection` header: 3 -> 4
   - `calendarSection`: 4 -> 5
   Add `customVocabularySection` call to the `Form` body between `generalSection` and
   `permissionsSection`.

3. **New file `SettingsVocabularySection.swift`.**
   Extension on `SettingsView` with `customVocabularySection`. Three rows:
   - Row 1: master toggle with subtitle (same `VStack(alignment:spacing:)` pattern as AI toggle)
   - Row 2: "Vocabulary List" row with trailing `Edit List (N)` button, hidden when off
   - Row 3: calendar toggle with subtitle, hidden when off
   Sheet presentation for `VocabularyListSheet`.

4. **New file `VocabularyListSheet.swift`.**
   - Header: kicker "SETTINGS", serif-27 title "Vocabulary List", 13pt subtitle
   - Add field + Add button; Return commits; field focused on open; clears on success
   - Inline validation message under add field
   - Scrollable term list with editable TextFields and delete buttons
   - Empty state message
   - Footer: Divider + right-aligned Done button (.defaultAction)
   - Width ~520pt, list area capped at ~320pt

5. **Update `SettingsLayoutTests`.**
   Re-index the expected titles array to include "Custom Vocabulary" at index 1.

6. **New tests in `SettingsViewModelTests` or a new `SettingsVocabularyTests` file.**
   - `customVocabularyEnabled` defaults to true, persists toggle, loads from store
   - `calendarVocabularyEnabled` defaults to true, persists toggle, loads from store
   - `addVocabularyTerm` round-trips through the store
   - Duplicate rejection returns `.duplicate`
   - Over-length rejection returns `.tooLong`
   - Whitespace-only input adds nothing and returns nil
   - `removeVocabularyTerm` persists removal
   - `updateVocabularyTerm` persists edit, rejects duplicates
   - `vocabularyTerms` count matches after add/remove
   - Revert on store failure for toggle setters

## Tests

- `customVocabularyEnabledDefaultAndPersist`: default true, toggle off/on, verify persisted
- `calendarVocabularyEnabledDefaultAndPersist`: same pattern
- `loadReadsVocabularySettingsFromStore`: pre-set values, load, verify
- `addVocabularyTermPersists`: add term, verify in store
- `addVocabularyTermRejectsDuplicate`: add same term twice, second returns `.duplicate`
- `addVocabularyTermRejectsTooLong`: 61-char term returns `.tooLong`
- `addVocabularyTermIgnoresWhitespace`: whitespace-only returns nil, no term added
- `addVocabularyTermTrimsWhitespace`: "  Acme  " stores as "Acme"
- `removeVocabularyTermPersists`: add then remove, verify gone
- `updateVocabularyTermPersists`: add then edit, verify updated
- `updateVocabularyTermRejectsDuplicate`: edit to match another, returns `.duplicate`
- `sectionTitlesReIndexed`: updated layout test with 6 titles
- `setCustomVocabularyEnabledRevertsOnFailure`: failable store, revert check
- `setCalendarVocabularyEnabledRevertsOnFailure`: failable store, revert check
- `vocabularyDeferredTestRemoved`: the old placeholder test is replaced
