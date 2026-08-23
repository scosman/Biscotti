---
status: complete
---

# Phase 2: Extraction and Assembly

## Overview

Builds the core extraction and assembly pipeline: `CasingNormalizer`, `NameExtractor`,
`CompanyExtractor`, `UncommonWordExtractor`, `VocabularyInputs`, `VocabularyAssembler`, and
`VocabularyService`. These are the types that take raw meeting data (user terms, attendee names,
email domains, event title/notes) and produce the ordered, de-duplicated, capped effective
vocabulary list. All extraction types are pure functions over plain values, making them fully
unit-testable without SwiftData or bundles. `VocabularyService` is the only stateful type,
reading from `DataStore` and threading results through the pure assembler.

## Steps

1. **Create `CasingNormalizer.swift`** in `Sources/Vocabulary/`.
   - `enum CasingNormalizer` with:
     - `static func isAllUppercase(_ text: String) -> Bool` — true when the string has at least
       one cased letter and no lowercase letter.
     - `static func normalize(forms: [String], sourceIsAllUppercase: Bool) -> String` — applies
       the three-rule casing logic from functional spec §3.5.

2. **Create `NameExtractor.swift`** in `Sources/Vocabulary/`.
   - `enum NameExtractor` with:
     - `static func firstNames(from names: [String], rawInviteeCount: Int) -> [String]`
   - Guards on `rawInviteeCount <= maxInvitees`.
   - Extracts first whitespace-separated token per name, strips trailing punctuation,
     skips short tokens, applies per-person `CasingNormalizer`.

3. **Create `CompanyExtractor.swift`** in `Sources/Vocabulary/`.
   - `enum CompanyExtractor` with:
     - `static func companyNames(from emails: [String]) -> [String]`
   - Lowercases, strips free-mail domains, applies domain cap, extracts registrable label
     via `PublicSuffixes.multiPart`, formats as capitalized words.

4. **Create `UncommonWordExtractor.swift`** in `Sources/Vocabulary/`.
   - `enum UncommonWordExtractor` with:
     - `static func terms(title: String?, notes: String?, uncommon: (Set<String>) -> Set<String>) -> [String]`
   - Scrubs URLs/emails/digit-tokens via pre-compiled `NSRegularExpression`s, tokenizes on
     non-letters, groups by lowercased key, applies the three guards, normalizes casing.

5. **Create `VocabularyInputs.swift`** in `Sources/Vocabulary/`.
   - `public struct VocabularyInputs: Sendable, Equatable` with fields: `userTerms`, `calendarEnabled`,
     `eventTitle`, `eventNotes`, `attendeeNames`, `attendeeEmails`, `rawInviteeCount`.

6. **Create `VocabularyAssembler.swift`** in `Sources/Vocabulary/`.
   - `public enum VocabularyAssembler` with:
     - `static func assemble(_ inputs: VocabularyInputs, uncommon: (Set<String>) -> Set<String>) -> [String]`
   - Takes at most 12 user terms, appends names/companies/uncommon words when calendar is
     enabled, de-duplicates case-insensitively, caps at 40 terms and 700 characters.

7. **Create `VocabularyService.swift`** in `Sources/Vocabulary/`.
   - `public final class VocabularyService: Sendable` with `init(store: DataStore)`.
   - `public func effectiveVocabulary(meetingID: UUID) async -> [String]`
   - Reads settings + calendarContext from the store, builds `VocabularyInputs`, calls
     `VocabularyAssembler.assemble` with `CommonWordList.uncommonFilter`.

## Tests

- `CasingNormalizerTests.testAllUppercaseSourceLowercases` — all-caps string lowercases the term.
- `CasingNormalizerTests.testInconsistentCasingLowercases` — two differing forms lowercase.
- `CasingNormalizerTests.testConsistentCasingPreserved` — a single form is preserved verbatim.
- `CasingNormalizerTests.testIsAllUppercase` — verifies detection of all-caps, mixed, empty.
- `NameExtractorTests.testFirstTokenExtracted` — multi-word names yield the first token.
- `NameExtractorTests.testInviteeCapExcludesNames` — 21 invitees returns empty.
- `NameExtractorTests.testInviteeCapIncludesNames` — 20 invitees includes names.
- `NameExtractorTests.testEmptyAndShortNamesSkipped` — empty, whitespace-only, and 1-char tokens skipped.
- `NameExtractorTests.testTrailingPunctuationStripped` — trailing `.` and `,` removed.
- `NameExtractorTests.testAllCapsNameLowercased` — shouty name lowercased per person.
- `CompanyExtractorTests.testFreeMailDomainsStripped` — gmail.com etc. removed.
- `CompanyExtractorTests.testDomainCapAppliedAfterStripping` — 5 unique domains included, 6 excluded.
- `CompanyExtractorTests.testPublicSuffixHandling` — `mail.acme.co.uk` → `Acme`.
- `CompanyExtractorTests.testHyphenatedDomain` — `acme-corp.com` → `Acme Corp`.
- `CompanyExtractorTests.testShortLabelSkipped` — 2-char labels skipped.
- `CompanyExtractorTests.testWwwSkipped` — `www` label skipped.
- `UncommonWordExtractorTests.testUrlsAndEmailsScrubbed` — URLs and email addresses removed.
- `UncommonWordExtractorTests.testDigitTokensScrubbed` — tokens with digits removed.
- `UncommonWordExtractorTests.testParakeetExample` — "Project Parakeet Team Meeting" yields `Parakeet`.
- `UncommonWordExtractorTests.testLongTextHighHitRate` — >5 words with >20% uncommon drops all.
- `UncommonWordExtractorTests.testAbsoluteCap` — >15 uncommon words drops all.
- `UncommonWordExtractorTests.testEmptyInput` — returns empty.
- `VocabularyAssemblerTests.testPriorityOrder` — user terms first, then names, companies, uncommon.
- `VocabularyAssemblerTests.testCaseInsensitiveDedupe` — higher-priority casing wins.
- `VocabularyAssemblerTests.testUserTermCap` — only first 12 user terms contribute.
- `VocabularyAssemblerTests.testMaxTermsCap` — truncated to 40.
- `VocabularyAssemblerTests.testCharacterCap` — truncated to 700 chars joined.
- `VocabularyAssemblerTests.testCalendarDisabled` — yields user list only.
- `VocabularyAssemblerTests.testNearCapInteraction` — 12 user + 21 names + 5 companies = 38, room for 2 uncommon.
- `VocabularyServiceTests.testEffectiveVocabulary` — integration test with in-memory store.
- `VocabularyServiceTests.testFeatureOff` — master toggle off returns empty.
- `VocabularyServiceTests.testCalendarToggleOff` — returns user terms only.

## Performance Measurement (arch §3.10, functional spec §10)

Measured on-machine (Apple M1 Pro) with the real bundled `common_words_en.txt` and a realistic
full-length event description (Zoom boilerplate, multi-item agenda, URLs, email addresses, dial-in
numbers — the kind of `eventNotes` a typical corporate meeting produces).

| Metric | Value |
|---|---|
| Word-list file size | 226,380 bytes (221 KB) |
| Word count | 27,827 words |
| Assembly time (avg of 10 runs, 1 warmup) | **~9 ms** (8,960 µs) |
| Total for 10 runs | 89.6 ms |
| Result term count | 22 |

The 9 ms average is well under the 100 ms target. The linear-scan algorithm (arch §3.10) is
sufficient; the binary-search/mapped-file fallback is not needed. The word list is loaded, scanned,
and released each call — nothing is retained between invocations.
