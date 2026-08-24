---
status: complete
---

# Architecture: Custom Vocabulary

Single-document architecture — one new module plus wiring into four existing ones. No component
designs (`components/`) are needed; the internal complexity all sits in one module and is specified
in full below.

## 1. Topology

```
                       ┌──────────────────────┐
                       │  Vocabulary (NEW)    │  BiscottiKit module
                       │  assembly + word list│
                       └──────────┬───────────┘
                    ┌─────────────┼──────────────┐
                    │             │              │
        TranscriptionService  MeetingDetailUI    DataStore
        (effective vocab      (alert suppression  (settings +
         per job)              check)              calendar context)

        SettingsUI ──────────────────────────────► DataStore
        (three settings, via its existing settings path — no Vocabulary dependency)
```

**Deviation from `specs/architecture.md` component 13, recorded deliberately.** That doc says
`Vocabulary` "owns the custom-vocabulary source-of-truth *and* merge logic," including "store/edit the
app-wide vocab list (in settings)." In this codebase, `AppSettings` is the settings source of truth
and every view model mutates it through `DataStore.updateSettings`. Putting a service in front of only
the vocabulary fields would make them the one inconsistent setting. So:

- `Vocabulary` owns **assembly, extraction, limits, and the word list** — the substance.
- The **storage** stays in `AppSettings`, and `SettingsUI` reads/writes it exactly like
  `aiAnalysisEnabled` and `summaryPrompt`.

`specs/architecture.md` component 13 should be reworded to match at the end of the project.

## 2. Data model

### 2.1 `AppSettings` (two additive fields)

```swift
/// Master switch for custom vocabulary. When false no prompt is sent at all.
public var customVocabularyEnabled: Bool = true
/// Whether per-meeting terms are derived from the associated calendar event.
public var calendarVocabularyEnabled: Bool = true
```

`customVocabulary: [String]` already exists and is unchanged.

Mirror both onto `AppSettingsData`, `settings()`, `updateSettings()`, and `AppSettings.init`. Defaulted
additive properties → **no migration stage**; `DataStoreSchemaV1` and `DataStoreMigrationPlan` are
untouched (the existing comment in `DataStore.swift` documents exactly this case).

### 2.2 `TranscriptVersionData` (one additive field)

```swift
public let vocabularyUsed: [String]
// init gains `vocabularyUsed: [String] = []` as the last parameter — source-compatible.
```

Populated from `TranscriptRecord.vocabularyUsed` in `transcriptVersions(meetingID:)`.
`MeetingDetailViewModel` already loads versions for the picker, so the alert-suppression check
(§5.3) needs **no new store method**.

### 2.3 No new persisted entities

Everything else is computed per job and thrown away. The extracted terms are visible only through
`TranscriptRecord.vocabularyUsed`.

## 3. The `Vocabulary` module

New target in `Packages/BiscottiKit/Package.swift`:

```swift
.target(
    name: "Vocabulary",
    dependencies: ["DataStore"],
    resources: [.process("Resources")],
    swiftSettings: warningsAsErrors
),
.testTarget(
    name: "VocabularyTests",
    dependencies: ["Vocabulary", "DataStore"],
    swiftSettings: warningsAsErrors
),
```

### 3.1 File layout

| File | Responsibility |
|---|---|
| `VocabularyService.swift` | The only stateful type. Reads the store, calls the pure assembler. |
| `VocabularyInputs.swift` | The plain-value input struct. |
| `VocabularyAssembler.swift` | Pure. Orders, de-duplicates, applies caps. |
| `NameExtractor.swift` | Attendee first names (§3.2 of the functional spec). |
| `CompanyExtractor.swift` | Email domains → company names (§3.3). |
| `UncommonWordExtractor.swift` | Tokenizing + the three guards (§3.4.2–3.4.3). |
| `CasingNormalizer.swift` | The casing rules (§3.5). |
| `CommonWordList.swift` | Loads and scans the bundled resource. |
| `FreeMailDomains.swift` | `Set<String>` constant, ~80 entries. |
| `PublicSuffixes.swift` | `Set<String>` constant of known multi-part suffixes. |
| `VocabularyLimits.swift` | Every threshold, named. |
| `Resources/common_words_en.txt` | The generated asset. |

### 3.2 `VocabularyLimits`

```swift
public enum VocabularyLimits {
    public static let maxUserTerms = 12
    public static let maxEffectiveTerms = 40
    public static let maxJoinedCharacters = 700
    public static let maxSingleTermLength = 60
    public static let maxInvitees = 20
    public static let maxUniqueDomains = 5
    public static let minTokenLength = 3
    public static let minNameLength = 2
    /// Hit-rate ceiling when there are `shortTextWordCount` or fewer checked words.
    public static let shortTextHitRateCeiling = 0.34
    public static let shortTextWordCount = 5
    /// Hit-rate ceiling above `shortTextWordCount` checked words.
    public static let longTextHitRateCeiling = 0.25
}
```

No threshold is inlined anywhere else.

### 3.3 `VocabularyService`

```swift
/// Assembles the effective custom vocabulary for a transcription job.
///
/// Not `@MainActor`: assembly reads a bundled word list from disk and scans it,
/// which must not run on the main actor. Callers `await` from wherever they are.
public final class VocabularyService: Sendable {
    private let store: DataStore
    private let logger = Logger(subsystem: "net.scosman.biscotti", category: "Vocabulary")

    public init(store: DataStore)

    /// The effective vocabulary for one transcription job, already ordered,
    /// de-duplicated, and capped. Empty when the feature is off.
    ///
    /// Never throws: a missing word list, an unreadable store, or a missing
    /// snapshot degrades the result, it does not fail the caller.
    public func effectiveVocabulary(meetingID: UUID) async -> [String]
}
```

`DataStore` is an `actor`, so it is `Sendable` and the class is trivially `Sendable`.

Body:

1. `guard let settings = try? await store.settings() else { return [] }`
2. `guard settings.customVocabularyEnabled else { return [] }` — short-circuits before any I/O.
3. `let context = settings.calendarVocabularyEnabled ? try? await store.calendarContext(meetingID:) : nil`
4. Build `VocabularyInputs` from `settings` + `context`.
5. `return VocabularyAssembler.assemble(inputs, uncommon: CommonWordList.uncommonFilter(logger:))`

### 3.4 `VocabularyInputs` — the pure boundary

```swift
public struct VocabularyInputs: Sendable, Equatable {
    public var userTerms: [String] = []
    public var calendarEnabled: Bool = false
    public var eventTitle: String?
    public var eventNotes: String?
    /// Organizer first, then participants. Raw `PersonData.name` values.
    public var attendeeNames: [String] = []
    /// Raw email addresses from organizer + participants.
    public var attendeeEmails: [String] = []
    /// Organizer + participants counted before de-duplication.
    public var rawInviteeCount: Int = 0
}
```

Everything below this line is a pure function over plain values — no SwiftData, no EventKit, no
`Bundle` except through the injected closure. That is what makes the whole feature unit-testable.

### 3.5 `VocabularyAssembler`

```swift
public enum VocabularyAssembler {
    /// - Parameter uncommon: given a set of lowercased candidate words, returns
    ///   the subset that is NOT in the common-word list. Injected so tests need
    ///   no bundle and so a load failure can degrade to "no uncommon words".
    public static func assemble(
        _ inputs: VocabularyInputs,
        uncommon: (Set<String>) -> Set<String>
    ) -> [String]
}
```

Algorithm:

1. `terms = inputs.userTerms.map(trim).filter(!isEmpty).prefix(maxUserTerms)` — verbatim, no casing
   normalization.
2. If `inputs.calendarEnabled`, append in order:
   `NameExtractor.firstNames(from:count:)`, `CompanyExtractor.companyNames(from:)`,
   `UncommonWordExtractor.terms(title:notes:uncommon:)`.
3. De-duplicate on `lowercased()`, keeping the first occurrence and its casing (`Set<String>` of seen
   keys + an ordered result array — stable and O(n)).
4. `prefix(maxEffectiveTerms)`.
5. Drop from the end while `terms.joined(separator: ", ").count > maxJoinedCharacters`. Computed
   incrementally (running total) rather than re-joining per iteration.

### 3.6 `NameExtractor`

```swift
enum NameExtractor {
    static func firstNames(from names: [String], rawInviteeCount: Int) -> [String]
}
```

- `guard rawInviteeCount <= VocabularyLimits.maxInvitees else { return [] }`
- Per name: trim; skip if empty; take the first whitespace-separated token; skip if shorter than
  `minNameLength`; strip trailing punctuation (`.`, `,`) that some calendars leave on.
- Casing: `CasingNormalizer.normalize(forms: [token], sourceIsAllUppercase: isAllUppercase(name))` —
  evaluated per person, so one shouty entry does not lowercase everyone.

### 3.7 `CompanyExtractor`

```swift
enum CompanyExtractor {
    static func companyNames(from emails: [String]) -> [String]
}
```

1. Lowercase each email, take the substring after `@`, drop empties.
2. Remove any domain in `FreeMailDomains.all`.
3. `let unique = Set(remaining)`; `guard unique.count <= maxUniqueDomains else { return [] }`.
4. Per unique domain, in first-seen order: split on `.`; walk from the right matching the longest
   entry in `PublicSuffixes.multiPart` (e.g. `co.uk`); the registrable label is the one immediately
   before the matched suffix, or the second-to-last label when nothing matches.
5. Skip labels of 2 characters or fewer, and skip `www`.
6. Format: split on `-`, capitalize the first letter of each part, join with a space.
   `acme-corp.com` → `Acme Corp`.
7. No casing normalization — this string is synthesized, not observed.

### 3.8 `UncommonWordExtractor`

```swift
enum UncommonWordExtractor {
    static func terms(
        title: String?,
        notes: String?,
        uncommon: (Set<String>) -> Set<String>
    ) -> [String]
}
```

1. `let source = [title, notes].compactMap { $0 }.joined(separator: "\n")`; return `[]` if empty.
2. **Scrub**, in this order, with pre-compiled `NSRegularExpression`s held as `static let`:
   - URLs (`https?://…`, `www.…`)
   - email addresses
   - any whitespace-delimited token containing a decimal digit
3. **Tokenize**: split on anything that is not a Unicode letter; keep tokens of at least
   `minTokenLength` letters.
4. **Group** by `lowercased()` key, preserving every observed surface form in encounter order.
5. `let checked = Set(keys)`; return `[]` if empty.
6. `let miss = uncommon(checked)`.
7. **Guards** — return `[]` when either holds. There is no absolute cap on `miss.count`; see
   `functional_spec.md` §3.4.3 for why.
   - `checked.count <= shortTextWordCount && Double(miss.count) / Double(checked.count) > shortTextHitRateCeiling`
   - `checked.count > shortTextWordCount && Double(miss.count) / Double(checked.count) > longTextHitRateCeiling`
8. Emit the missing keys in first-encounter order, each passed through `CasingNormalizer` with
   `sourceIsAllUppercase` computed once over the scrubbed source.

### 3.9 `CasingNormalizer`

```swift
enum CasingNormalizer {
    /// True when the string has at least one cased letter and no lowercase letter.
    static func isAllUppercase(_ text: String) -> Bool

    /// - forms: every surface form observed for one term, in encounter order.
    static func normalize(forms: [String], sourceIsAllUppercase: Bool) -> String
}
```

`normalize`:
- `sourceIsAllUppercase` → `forms[0].lowercased()`
- `Set(forms).count > 1` → `forms[0].lowercased()`
- otherwise → `forms[0]` unchanged

### 3.10 `CommonWordList`

```swift
enum CommonWordList {
    /// Returns a closure suitable for `VocabularyAssembler.assemble(_:uncommon:)`.
    /// On any load failure, returns a closure that yields an empty set — i.e.
    /// "no word is uncommon", so the method contributes nothing.
    static func uncommonFilter(logger: Logger) -> (Set<String>) -> Set<String>

    /// Returns the members of `candidates` absent from the bundled list.
    static func uncommon(from candidates: Set<String>) throws -> Set<String>
}
```

**Algorithm (the measured one).** Candidates number in the tens; the list numbers in the tens of
thousands.

1. `Bundle.module.url(forResource: "common_words_en", withExtension: "txt")`, else throw.
2. `let text = try String(contentsOf: url, encoding: .utf8)`.
3. `var remaining = Set(candidates.map { $0[...] })` — a `Set<Substring>`. `Substring` hashes and
   compares by character content, so slices of different strings match correctly. This avoids
   allocating a `String` per line.
4. `for line in text.split(separator: "\n", omittingEmptySubsequences: true) { if remaining.contains(line) { remaining.remove(line); if remaining.isEmpty { break } } }`
5. Return `Set(remaining.map(String.init))`.
6. `text` goes out of scope at return — **nothing is retained**. This is a hard requirement, not an
   optimization: the module holds no static cache of the list, by design.

**Escalation path if measurement says it is too slow.** The file is sorted, so the fallback is
`Data(contentsOf:.mappedIfSafe)` plus a binary search over newline offsets — roughly 16 probes per
candidate, touching a few pages instead of the whole file. Do not build this speculatively; build it
only if the linear pass measures poorly, and record the numbers either way.

## 4. Word-list generation

`Tools/generate_common_words.py`, committed, run manually, not wired into any `make` target.

```python
# Regenerates Packages/BiscottiKit/Sources/Vocabulary/Resources/common_words_en.txt
# Run: uv run --with wordfreq python Tools/generate_common_words.py
from wordfreq import get_frequency_dict, zipf_frequency
words = get_frequency_dict('en', wordlist='large')
out = sorted(w for w in words
             if w.isalpha() and len(w) >= 3 and zipf_frequency(w, 'en') >= 3.0)
...write one word per line, LF-terminated, UTF-8...
```

The script prints the resulting word count and file size so the values can be recorded. Output is
sorted and deterministic, so regeneration produces a reviewable diff.

**Verification step, required during implementation:** confirm that the words used in the functional
spec's worked example behave as documented — in particular that `parakeet` is genuinely absent from
the generated list (zipf < 3.0). If it is present, the spec's example word changes; the 3.0 threshold
does **not**.

## 5. Wiring into existing modules

### 5.1 `TranscriptionService`

```swift
public init(store: DataStore, engine: any Transcribing, vocabulary: VocabularyService)
```

Source-breaking. Call sites to update: `AppCore+Live.swift:56`, `PreviewAppCore.swift:37`,
`CoreFixture.swift:509`, `SettingsAIEnhancementsTests.swift:258`, and four in
`TranscriptionServiceTests.swift`.

`runJob` computes the vocabulary **once**, before `runEngine`, and threads the same array into both
the engine call and the persistence call — so `vocabularyUsed` is exactly what the engine received,
never a recomputation:

```swift
let vocab = await vocabulary.effectiveVocabulary(meetingID: meetingID)
guard let result = await runEngine(meetingID: meetingID, paths: paths, vocabulary: vocab) else { … }
await persistAndPromote(meetingID: meetingID, result: result, vocabularyUsed: vocab)
```

`runEngine` and `persistAndPromote` each gain that parameter, replacing their hardcoded `[]`.
Re-transcription goes through the same path, so it naturally recomputes.

### 5.2 `SettingsUI`

- `SettingsViewModel` gains `customVocabularyEnabled`, `calendarVocabularyEnabled`, and
  `vocabularyTerms: [String]`, loaded in `load()` from the settings DTO it already reads, plus:
  `setCustomVocabularyEnabled(_:)`, `setCalendarVocabularyEnabled(_:)`, `addVocabularyTerm(_:)`,
  `removeVocabularyTerm(at:)`, `updateVocabularyTerm(at:to:)`. Each write goes through the existing
  `updateSettings` path, exactly like `setAIAnalysisEnabled`.
- Validation (trim, case-insensitive duplicate rejection, `maxSingleTermLength`) lives on the view
  model and returns a typed result so the sheet can show the right inline message:
  ```swift
  enum VocabularyTermError: Equatable { case duplicate(String), tooLong }
  func addVocabularyTerm(_ raw: String) async -> VocabularyTermError?
  ```
  Whitespace-only input returns `nil` and adds nothing.
- New file `SettingsVocabularySection.swift` (mirrors `SettingsCalendarSection.swift`) holding the
  section as an extension on `SettingsView`.
- New file `VocabularyListSheet.swift` in `SettingsUI`. It stays in `SettingsUI` rather than becoming
  its own module — unlike `SummaryPromptUI`, it has exactly one presentation site.
- **`sectionTitles` placement.** `"Custom Vocabulary"` sits at index 4, between AI Enhancements (3)
  and Calendars (5). Every `sectionTitles[N]` reference and every settings test asserting on titles
  must match these indices.

### 5.3 `MeetingDetailUI`

`MeetingDetailViewModel` gains a `vocabulary: VocabularyService` dependency.

`correctAssociation(eventKey:)` currently ends with the `TODO(re-transcribe-prompt)` comment. It
becomes:

```swift
if eventKey != nil {
    showReTranscribeAfterCorrection = await shouldOfferReTranscribe()
}
```

```swift
private func shouldOfferReTranscribe() async -> Bool {
    guard let newest = transcriptVersions.first else { return false }   // sorted desc
    guard audioIsPresent else { return false }
    guard let settings = try? await core.settings(),
          settings.customVocabularyEnabled,
          settings.calendarVocabularyEnabled else { return false }
    let recomputed = await vocabulary.effectiveVocabulary(meetingID: meetingID)
    return recomputed != newest.vocabularyUsed
}
```

Ordered comparison, not set comparison — order is meaningful to the prompt.

`removeAssociation()` keeps setting the flag `false`. Both `TODO(re-transcribe-prompt)` markers
(`:58` and `:951`) are deleted. `reTranscribeAfterCorrection()` and `dismissReTranscribePrompt()` are
already implemented and unchanged; the view's alert conditional is un-suppressed.

### 5.4 `AppCore`

`AppCore.live` constructs one `VocabularyService(store:)` and injects it into `TranscriptionService`
and into `MeetingDetailViewModel`'s construction path. `PreviewAppCore` and `CoreFixture` do the same
with their in-memory stores — the service needs no fake, because it is pure over store reads and the
bundled resource is available to tests.

## 6. Error handling

| Failure | Handling |
|---|---|
| `store.settings()` throws | `effectiveVocabulary` returns `[]`. Logged at `.error`. Transcription proceeds unbiased. |
| `store.calendarContext()` throws or returns `nil` | User's list only. Not logged — `nil` is the normal ad-hoc case. |
| Word list resource missing/unreadable | `uncommonFilter` yields an empty set → no uncommon words. Logged at `.error` once per call. Names, company names, and the user's list are unaffected. |
| Regex construction fails | Impossible for `static let` literals; force-unwrap is acceptable and is the existing convention, but the extractor is written so a scrub-stage failure degrades to "no scrubbing" rather than crashing. |
| Settings write fails in the editor | Surfaced the same way other Settings writes are; the sheet does not invent new error UI. |

**Nothing in this feature can fail a transcription job.** That is the governing rule.

## 7. Concurrency

- `VocabularyService` is a non-isolated `Sendable` final class. `effectiveVocabulary` is `async` and
  runs on the cooperative pool, so file reading and the list scan never touch the main actor.
- `TranscriptionService` is `@MainActor`; it `await`s the service, which hops off and back.
- `MeetingDetailViewModel` is `@MainActor`; the suppression check is `await`ed inside the existing
  async `correctAssociation`.
- All extractor types are stateless `enum`s with `static` methods over `Sendable` values.

## 8. Testing strategy

New target `VocabularyTests`, plus additions to three existing targets. Swift Testing (`@Test`), the
existing convention.

**`VocabularyAssemblerTests`** — priority order across all four sources; case-insensitive dedupe keeps
the higher-priority casing; the 12-term user cap; the 40-term cap; the 700-character cap dropping
whole terms from the end; master toggle off yields `[]`; calendar toggle off yields the user's list
only; no snapshot yields the user's list only; the documented near-cap interaction (12 + 21 + 5
leaves room for 2 uncommon words).

**`NameExtractorTests`** — 20 invitees included / 21 excluded; first token only; empty and
whitespace-only names skipped; no name derived from an email; 1-character token skipped; all-caps
name lowercased per person, not globally.

**`CompanyExtractorTests`** — free-mail domains stripped; the 5-domain cap applied *after* stripping;
`mail.acme.co.uk` → `Acme`; `acme-corp.com` → `Acme Corp`; 2-character label skipped; `www` skipped;
malformed addresses ignored.

**`UncommonWordExtractorTests`** — URLs, emails, and digit-bearing tokens scrubbed before tokenizing;
tokens under 3 letters dropped; case-insensitive grouping; the "Project Parakeet Team Meeting" case
passing under the 34% ceiling; a >5-word case failing at 33%; a French description dropping
everything; a 16-uncommon-word description returning all 16 (no absolute cap); empty input returning
`[]`. Uses an injected `uncommon` closure — no bundle.

**`CommonWordListTests`** — exercises the **real** bundled resource, so the asset itself is under
test: known-common words are absent from the result (`meeting`, `project`, `team`, `report`); at
least one genuinely rare word is returned; the file is non-empty and sorted; a candidate set that is
fully common returns an empty set. No assertion on the exact word count — that would break on every
regeneration.

**`CasingNormalizerTests`** — all-caps source lowercases; two differing forms lowercase; a single
form is preserved verbatim, including title-initial capitals.

**`SettingsUITests`** (additions) — the section renders; rows 2 and 3 are hidden when the master
toggle is off; add/edit/remove round-trips through the store; duplicates rejected with
`.duplicate`; an over-length term rejected with `.tooLong`; `Edit List (N)` reflects the count; the
re-indexed `sectionTitles` assertions.

**`MeetingDetailUITests`** (additions) — the alert precondition matrix: no transcript → no alert;
audio missing → no alert; either toggle off → no alert; unchanged vocabulary → no alert; changed
vocabulary → alert; association removed → no alert.

**`TranscriptionServiceTests`** (updates) — the new init at all call sites; the fake engine captures
`customVocabulary` and the test asserts the persisted `vocabularyUsed` is byte-identical to it;
re-transcription recomputes.

**Performance** is *measured*, not asserted — timing assertions are flaky in CI. The implementer runs
assembly against a realistic full-length event description, and records the word-list file size, the
word count, and the elapsed time in the phase plan. Any result over the 100 ms target triggers the
§3.10 escalation path.

**Not covered by automated tests:** whether biasing actually improves real transcripts. That remains
the `make test-ai` `customVocabWordMatch` test, which is unchanged by this project.

## 9. What this project does not touch

- `Packages/Transcription` — no source change, so the manual-test staleness rule is not triggered and
  `tx_*` steps stay green.
- `VocabularyFormatter` — its 800-character backstop stays as a second line of defence behind the
  module's 700-character cap.
- `DataStoreSchemaV1` / `DataStoreMigrationPlan` — additive defaulted fields only.
