---
status: complete
---

# Functional Spec: Custom Vocabulary

## 1. Purpose

Biscotti's transcriber mis-hears words that are rare in general English: personal names, company
names, product codenames, and technical jargon. WhisperKit can be biased toward a supplied word list
through `promptTokens`. This project gives Biscotti a word list to supply, from two sources:

1. **A list the user maintains in Settings**, applied to every meeting.
2. **Words derived automatically from the meeting's calendar event** — attendee first names, company
   names from email domains, and uncommon words from the event title and description.

Both feed one **effective vocabulary** per transcription job, which is handed to the engine and
recorded on the resulting transcript.

## 2. Current state (what is already built)

This project completes a partly-built feature. Do not rebuild these:

| Piece | State |
|---|---|
| `argmax-oss-swift` v1.1.0 + `promptTokens` | Done. Casing is preserved; the `customVocabWordMatch` AI test passes on hardware. |
| `Transcription.VocabularyFormatter` | Done. `[String]` → `"Transcript mentioning: a, b, c."`, with an 800-character backstop. |
| `Transcribing.processAudio(mic:system:customVocabulary:)` | Done. Accepts the list. |
| `transcribe-cli --vocab` | Done. |
| `AppSettings.customVocabulary: [String]` | Field exists in SwiftData; `DataStore.settings()` / `updateSettings()` exist. Nothing reads or writes it. |
| `TranscriptRecord.vocabularyUsed` | Field exists; always written empty. |
| Re-transcribe-after-correction plumbing | Exists in `MeetingDetailViewModel`, UI suppressed (`showReTranscribeAfterCorrection` hardcoded `false`). |

Gaps this project fills: the `Vocabulary` module, the Settings section and its editor, the automatic
extraction, the `TranscriptionService` wiring, and the re-transcribe alert.

## 3. Vocabulary sources

### 3.1 The user's list (app-wide)

- An ordered list of terms stored in `AppSettings.customVocabulary` (SwiftData, via
  `DataStore.settings()` / `updateSettings()`). **Not** `UserDefaults` — every other setting lives in
  `AppSettings`, and the field already exists.
- Terms are used **verbatim**. Casing normalization (§3.5) does **not** apply to them: the user typed
  what they meant, and Whisper mirrors prompt casing into its output.
- A term may be a multi-word phrase. `VocabularyFormatter` joins terms with `", "`, so phrases work.
- Order is insertion order, and that order **is** the priority order (§3.6).
- **At most 12 terms** from this list reach the effective vocabulary. The stored list itself is not
  capped — the user may keep as many terms as they like — but only the **first 12** in stored order
  contribute. This reserves the rest of the 40-term budget for calendar-derived words, which would
  otherwise be starved by a long user list. There is deliberately **no warning UI** for this (§5.1).

### 3.2 Attendee first names

Source: `Meeting.participants` (`Person.name`) plus `Meeting.organizer`, populated from the
`CalendarSnapshot` at association time.

- **Invitee cap:** if the raw invitee count (organizer + participants, counted **before**
  de-duplication) is **greater than 20**, contribute **no names**. Large meetings are not personal
  enough for the names to be worth prompt budget.
- **First name only:** the first whitespace-separated token of `Person.name`.
- People with an empty or whitespace-only `name` are skipped. A name is **never** derived from the
  email local part.
- Tokens shorter than 2 characters are skipped.
- No commonness filter — every first name is taken, including common ones like "Mark".
- Casing normalization (§3.5) applies.

### 3.3 Company names from email domains

Source: the email addresses of the organizer and participants.

- **Strip free-mail and consumer-ISP domains first.** A bundled `Set<String>` of roughly 80 known
  domains (gmail.com, outlook.com, hotmail.com, icloud.com, me.com, yahoo.*, aol.com, proton.me,
  gmx.*, qq.com, 163.com, mail.ru, yandex.*, naver.com, comcast.net, btinternet.com, orange.fr,
  and similar). Free-mail domains are removed **before** the domain count is taken.
- **Domain cap:** if the number of **unique remaining** domains is **greater than 5**, contribute no
  company names.
- **Extract the registrable label:** the label immediately before the public suffix.
  `alice@mail.acme.co.uk` → `acme`. A bundled set of known multi-part suffixes (`co.uk`, `com.au`,
  `co.jp`, `com.br`, `co.za`, `ac.uk`, `com.cn`, `net.au`, and similar) covers the common cases; a
  full Public Suffix List is not bundled.
- **Format the label:** replace hyphens with spaces and capitalize each part. `acme-corp.com` →
  `Acme Corp`.
- Labels of 2 characters or fewer are skipped.
- Casing normalization (§3.5) does **not** apply — the casing here is synthesized, not observed.

### 3.4 Uncommon words from title and description

Source: `CalendarSnapshot.title` + `CalendarSnapshot.eventNotes`.

#### 3.4.1 The bundled common-word list

A list of **common** English words is baked into the app. A candidate word is treated as **uncommon**
when it is **not** in that list.

- Generated once from `wordfreq`, `wordlist='large'`, locale `en`, keeping words where
  `zipf_frequency >= 3.0`, `w.isalpha()`, and `len(w) >= 3`. No scores are stored — membership alone
  decides.
- One lowercase word per line, sorted, newline-separated plain text.
- Committed to the repo as a module resource, alongside the generator script, so the asset is
  reproducible and reviewable in a diff.

#### 3.4.2 Candidate extraction

Applied to the concatenation of title and description:

1. Remove URLs, email addresses, and any token containing a digit. Conferencing boilerplate (join
   links, dial-in numbers, meeting IDs, passcodes) is the bulk of most `eventNotes` and must not
   reach the word list.
2. Split the remainder on any non-letter character.
3. Keep tokens of **3 or more** letters.
4. De-duplicate **case-insensitively**, keeping the surface forms observed for each (needed by §3.5).

The surviving set is the **checked words**. Membership lookup uses the lowercased token.

#### 3.4.3 Guards

The uncommon-word method contributes **nothing at all** (names and company names are unaffected) when
any of these hold:

| Guard | Rule | Why |
|---|---|---|
| Absolute cap | more than **15** uncommon words | "A few outliers", not a flood of context. |
| Hit rate, short text | **checked words ≤ 5** and uncommon ÷ checked **> 0.34** | A foreign-language short title reads as almost all-uncommon. |
| Hit rate, longer text | **checked words > 5** and uncommon ÷ checked **> 0.20** | A non-English description misses the English list almost entirely and would actively damage transcription. |

Zero checked words contributes nothing and is not an error.

Worked example — *"Project Parakeet Team Meeting"*: 4 checked words, 1 uncommon (`parakeet`) = 25%.
Checked ≤ 5, so the 34% threshold applies → 25% passes → `Parakeet` is contributed. This is the
motivating example from `specs/app_overview.md`, and the two-tier threshold exists to keep it working.

### 3.5 Casing rules

Whisper mirrors prompt casing **and** prompt spelling into its output (validated on hardware — see
`specs/research/argmax/README.md` Gotcha #16, finding (b)/(d)). Casing therefore matters.

**Applies to:** attendee first names (§3.2) and uncommon words (§3.4).
**Does not apply to:** the user's own list (§3.1, verbatim) or company names (§3.3, synthesized).

Rules, in order:

1. **All-uppercase source.** If every letter-token in the source string is uppercase (a shouted title,
   an all-caps calendar name), the casing carries no information → lowercase the extracted terms from
   that source. Applied per source string, and to `Person.name` individually.
2. **Inconsistent casing across occurrences.** If a term appears with more than one casing in the
   source text (e.g. both `notion` and `Notion`), the evidence is ambiguous → use the lowercase form.
3. **Consistent casing.** Otherwise use the observed surface form exactly. A single occurrence counts
   as consistent — including a word capitalized only because it starts a Title Case event title.
   `"Project Parakeet Team Meeting"` therefore yields `Parakeet`, not `parakeet`. This is deliberate:
   an uncommon word in an event title is far more often a proper noun than not, and forcing lowercase
   was measured to degrade accuracy.

### 3.6 Assembly into the effective vocabulary

For one transcription job:

1. If the **Custom Vocabulary** master toggle is **off** → the effective vocabulary is **empty**, and
   no prompt is sent. Nothing else in this section runs.
2. Start with the user's list (§3.1), in stored order, trimmed, empty entries dropped, then **take at
   most the first 12**.
3. If **Add Words from Calendar Events** is **on** and the meeting has a `CalendarSnapshot`, append in
   this order:
   a. attendee first names (§3.2)
   b. company names (§3.3)
   c. uncommon words from title and description (§3.4)
4. De-duplicate **case-insensitively**, keeping the **first** (higher-priority) occurrence and its
   casing.
5. Truncate to at most **40 terms**.
6. Truncate further so the joined term text (`", "` separators, matching what
   `VocabularyFormatter` produces) is at most **700 characters**. Drop whole terms from the end until
   it fits.

Both caps live in the `Vocabulary` module. `VocabularyFormatter`'s existing 800-character backstop is
left alone, so `Packages/Transcription` is untouched by this project and the manual-test staleness
rule is not triggered.

A meeting with no `CalendarSnapshot` (ad-hoc recording, or association removed) yields only the user's
list.

**Known consequence of the ordering.** Names outrank uncommon words, so a near-cap meeting can consume
most of the budget: 12 user terms + 21 names + 5 company names = 38 of the 40, leaving room for only
2 uncommon words. This is accepted — for a large meeting, attendee names are the more valuable signal,
and the uncommon-word method is the one most likely to add noise. Typical meetings (2–6 attendees)
are nowhere near the cap. The 700-character limit binds before the term count for long phrases.

## 4. Transcription integration

- `TranscriptionService.init` becomes `(store:engine:vocabulary:)` — source-breaking. All 8 call sites
  are updated (`AppCore+Live`, `PreviewAppCore`, `CoreFixture`, and the test files).
- `runEngine` replaces the hardcoded `customVocabulary: []` with the effective vocabulary for that
  meeting.
- `persistAndPromote` replaces the hardcoded `vocabularyUsed: []` with the same list, so each
  transcript records what it was actually biased with.
- Re-transcription **recomputes** the effective vocabulary. Correcting an association therefore
  produces a better transcript on re-run — which is what the alert in §6 offers.
- Vocabulary assembly failures never fail a transcription job. If the word list cannot be read or the
  snapshot cannot be loaded, the job proceeds with whatever terms were assembled (possibly none).

## 5. Settings

A new **Custom Vocabulary** section, placed directly after **AI Enhancements** in `SettingsView`.

**Header row**
- Title: `Custom Vocabulary`
- Subtitle: `Help Biscotti recognize uncommon words you use, like names or technical terms.`
- Toggle, default **on**. When off, the two rows below are hidden.

**Row — Vocabulary List** (visible only when the master toggle is on)
- Title: `Vocabulary List`
- Subtitle: `Words to watch for in every meeting.`
- Trailing button: `Edit List (N)`, where N is the current term count. Opens the editor sheet (§5.1).

**Row — Add Words from Calendar Events** (visible only when the master toggle is on)
- Title: `Add Words from Calendar Events`
- Subtitle: `Pull uncommon words from the event's title, description, and attendee names. English only.`
- Toggle, default **on**.

Both toggles are new `Bool` fields on `AppSettings` with defaults of `true`. They are additive
defaulted properties, so SwiftData handles them without a migration stage
(`DataStoreMigrationPlan` stays V1-only).

### 5.1 Vocabulary list editor (sheet)

- Presented as a sheet from the Settings section.
- Shows the terms in stored order, each with a delete control.
- An add field with an **Add** action; Return also commits.
- A term is editable in place.
- **Validation:** trim leading/trailing whitespace; ignore empty input; reject case-insensitive
  duplicates; cap a single term at 60 characters.
- **No budget warning and no hard limit in the editor.** The user may store any number of terms; only
  the first 12 contribute (§3.1). This is a deliberate choice — the alternative was warning copy that
  most users would never see, and a hard limit that would block a legitimate action. The `Edit List
  (N)` count is the only signal that the list is long.
- Changes autosave, matching the rest of Settings. A Done/Close control dismisses the sheet.
- Order is insertion order and is not user-reorderable in V1. Order is meaningful (§3.6 step 2), so
  reordering is a reasonable later addition.

## 6. Re-transcribe after attaching calendar metadata

When the user attaches or changes a meeting's calendar event **after** it has been transcribed, the
existing transcript was produced without that event's words. Offer a re-run.

- **Triggers:** setting an association on an unlinked meeting, **and** changing an existing
  association to a different event.
- **Does not trigger:** removing an association.
- **Preconditions**, all required:
  - the meeting already has at least one transcript,
  - the audio file is still present,
  - the **Custom Vocabulary** master toggle is on,
  - **Add Words from Calendar Events** is on,
  - the **recomputed effective vocabulary differs** from the newest transcript's `vocabularyUsed`
    (compared as an ordered list). Without this, relinking between two events that both yield no
    terms would offer a multi-minute re-run that produces a byte-identical transcript.
    `MeetingDetailViewModel` therefore takes a `Vocabulary` dependency.
- **Alert copy:**
  - Title: `Re-transcribe with keywords from this event?`
  - Message: `We'll use this event's title, description and attendee list to improve transcription accuracy.`
  - Buttons: `OK` (default) and `Cancel`.
- **OK** starts re-transcription through the existing `reTranscribeAfterCorrection()` path. **Cancel**
  dismisses and changes nothing.
- The existing `TODO(re-transcribe-prompt)` markers at `MeetingDetailViewModel.swift:58` and `:951`
  are removed as part of this.

## 7. Word list asset and generation

- **Generator:** a committed Python script under `Tools/`, using `wordfreq`, implementing §3.4.1.
  Run manually; not part of any build or CI target.
- **Output:** a committed plain-text resource in the `Vocabulary` module, bundled with
  `resources: [.process(...)]` (the precedent is `DesignSystem`).
- **Loading:** read transiently at assembly time and released immediately. The list is **never**
  retained between jobs. A few extra milliseconds per transcription is an acceptable trade for not
  carrying roughly a megabyte for the app's lifetime.
- **Lookup shape:** build a small set from the candidate words (tens of entries), then make one pass
  over the word list, marking candidates as common. Candidates left unmarked are the uncommon words.
  This is O(size of the bundled list) with only the small candidate set held. The implementation must
  **measure** the real cost and record the file size and elapsed time; if a single pass proves slow,
  the alternative (load the list into a `Set` and probe it) may be chosen instead, with the measured
  numbers as justification.

## 8. Edge cases and error handling

| Case | Behavior |
|---|---|
| No `CalendarSnapshot` (ad-hoc recording) | User's list only. |
| Master toggle off | Empty vocabulary, no prompt sent, no extraction work performed. |
| Calendar toggle off | User's list only. |
| Event with no attendees | No names, no company names; uncommon words still apply. |
| Attendees with names but no emails | Names apply; no company names. |
| All attendees on free-mail domains | No company names. |
| More than 20 invitees | No names. Company names and uncommon words still apply. |
| More than 5 unique non-free-mail domains | No company names. Names and uncommon words still apply. |
| Non-English title/description | Hit-rate guard drops the uncommon-word method. Names and company names still apply — they are language-agnostic. |
| Empty title and empty description | No uncommon words; not an error. |
| Word list resource missing or unreadable | Uncommon-word method contributes nothing; names, company names, and the user's list are unaffected; the job proceeds. Logged, not surfaced. |
| User's stored list longer than 12 | Only the first 12 in stored order contribute. Silent — no warning UI. |
| Effective list over budget | Truncated per §3.6 steps 5–6 (40 terms, then 700 characters). Silent. |
| Duplicate terms across sources | De-duplicated case-insensitively; highest-priority casing wins. |
| Duplicate term entered in the editor | Rejected with inline feedback; not added twice. |
| Re-transcribe alert conditions unmet | No alert; the association change still applies normally. |
| Association corrected while a transcription is running | The alert is not shown; the in-flight job keeps the vocabulary it started with. |

## 9. Configuration and defaults

| Setting | Storage | Default |
|---|---|---|
| Custom Vocabulary enabled | `AppSettings` (new `Bool`) | `true` |
| Add Words from Calendar Events | `AppSettings` (new `Bool`) | `true` |
| User term list | `AppSettings.customVocabulary` (exists) | empty |

Tunable constants, all owned by the `Vocabulary` module and named rather than inlined: max invitees
(20), max unique domains (5), max uncommon words (15), hit-rate thresholds (0.34 at ≤ 5 checked
words, 0.20 above), minimum token length (3), max user-list contribution (12), max effective terms
(40), max joined characters (700), max single-term length (60).

## 10. Constraints

- **Performance:** assembly runs once per transcription job, off the main actor. Target well under
  100 ms on Apple silicon, against a full-length event description. Must be measured, not assumed.
- **Memory:** the bundled word list is never retained beyond one assembly call. This is an explicit
  requirement, not a preference.
- **Language:** the uncommon-word method is English-only, and the Settings copy says so. Names and
  company names are language-agnostic.
- **Schema:** additive defaulted `AppSettings` fields only. No migration stage, no V2 schema.
- **Package boundary:** all new logic lives in `Vocabulary` (a BiscottiKit module, per
  `specs/architecture.md` component 13). `Packages/Transcription` is not modified by this project's
  phases (a prerequisite bump landed in its own earlier commit), so the manual-test staleness rule is
  not triggered by the phases themselves.
- **Testability:** extraction and assembly are pure functions over plain values, so they are unit
  testable without SwiftData, EventKit, or a model.

## 11. Out of scope

- Per-recording manual vocabulary additions (P3 in `specs/app_overview.md`).
- LLM-based vocabulary extraction from invites (a Project 10 leftover).
- Non-English uncommon-word extraction, or bundling non-English word lists.
- Surfacing `vocabularyUsed` anywhere in the UI.
- User-reorderable vocabulary lists.
- Warning UI when the user's stored list exceeds the 12-term contribution limit. Deliberately
  excluded; the `Edit List (N)` count is the only signal.
- The Pro SDK's real custom-vocabulary pass (`promptTokens` biasing remains the mechanism).
- Any change to `VocabularyFormatter` or the `Transcription` package.

## 12. Success criteria

1. A user can add, edit, and delete terms in Settings, and those terms bias every transcription.
2. Turning the master toggle off sends no vocabulary at all.
3. A meeting linked to a calendar event transcribes with attendee first names, company names, and
   uncommon title/description words added automatically — and `TranscriptRecord.vocabularyUsed`
   records exactly what was sent.
4. A meeting with a non-English description contributes no uncommon words, and a 50-person meeting
   contributes no names.
5. Attaching or changing a calendar event on an already-transcribed meeting offers a re-transcribe,
   and accepting it produces a transcript biased with the new event's words.
6. The bundled word list is not resident in memory between transcription jobs, and assembly cost is
   measured and recorded.
