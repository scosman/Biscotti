---
status: complete
---

# Phase 1: Foundation — Data Deltas + Word List

## Overview

Establishes the data-layer additions (two new `AppSettings` booleans, `TranscriptVersionData.vocabularyUsed`),
creates the `Vocabulary` target and test target in `Package.swift`, generates and commits the common-word
list asset, and implements the foundational types: `VocabularyLimits`, `FreeMailDomains`, `PublicSuffixes`,
and `CommonWordList`. Tests validate the real bundled asset and confirm `parakeet` is absent.

## Steps

1. **Add `customVocabularyEnabled` and `calendarVocabularyEnabled` to `AppSettings`.**
   Two new `Bool` properties with `true` defaults, additive — no migration needed.
   File: `Packages/BiscottiKit/Sources/DataStore/Models/AppSettings.swift`

2. **Mirror both fields onto `AppSettingsData`, `settings()`, and `updateSettings()`.**
   File: `Packages/BiscottiKit/Sources/DataStore/DataStore+ReadModels.swift`

3. **Add `vocabularyUsed: [String]` to `TranscriptVersionData`.**
   Populated from `TranscriptRecord.vocabularyUsed` in `transcriptVersions(meetingID:)`.
   File: `Packages/BiscottiKit/Sources/DataStore/DataStore+ReadModels.swift`

4. **Create `Tools/generate_common_words.py`.**
   Uses `wordfreq` to generate the common-word list per arch §4.

5. **Run the generator and commit `Resources/common_words_en.txt`.**
   Verify `parakeet` is absent (zipf < 3.0). Word count: **27,827 words**; file size: **221 KB** (226,380 bytes).

6. **Add the `Vocabulary` target and `VocabularyTests` test target to `Package.swift`.**
   Depends on `DataStore`, includes `resources: [.process("Resources")]`.

7. **Create `VocabularyLimits.swift`** — all named thresholds as static constants.

8. **Create `FreeMailDomains.swift`** — `Set<String>` of ~80 known free-mail domains.

9. **Create `PublicSuffixes.swift`** — `Set<String>` of common multi-part public suffixes.

10. **Create `CommonWordList.swift`** — loads the bundled resource, scans it with the
    O(list-size) algorithm from arch §3.10. `uncommonFilter(logger:)` and `uncommon(from:)`.

## Tests

- `CommonWordListTests.testKnownCommonWordsAreFiltered` — `meeting`, `project`, `team`, `report` are absent from the uncommon result.
- `CommonWordListTests.testRareWordIsReturned` — a genuinely rare word (e.g. `parakeet`) is returned as uncommon.
- `CommonWordListTests.testFileIsNonEmptyAndSorted` — the resource loads, is non-empty, and lines are sorted.
- `CommonWordListTests.testFullyCommonCandidatesReturnEmpty` — a candidate set of all common words returns an empty set.
- `CommonWordListTests.testParakeetAbsentFromList` — confirms the worked example holds (arch §4 verification).
- `VocabularyLimitsTests.testLimitsAreReasonable` — sanity check that constants have expected values.
- `DataStoreTests` additions — round-trip the new `customVocabularyEnabled`/`calendarVocabularyEnabled` settings fields; verify `TranscriptVersionData.vocabularyUsed` is populated from the record.
