---
status: complete
---

# Implementation Plan: Custom Vocabulary

Five phases. Each is independently reviewable and leaves the build green. Details live in
`functional_spec.md`, `ui_design.md`, and `architecture.md` — this file is only the order.

## Phases

- [x] **Phase 1 — Foundation: data deltas + the word list.**
  `AppSettings.customVocabularyEnabled` / `.calendarVocabularyEnabled` (+ `AppSettingsData`,
  `settings()`, `updateSettings()`); `TranscriptVersionData.vocabularyUsed`; the `Vocabulary` target
  and test target in `Package.swift`; `Tools/generate_common_words.py` and the generated
  `Resources/common_words_en.txt`; `VocabularyLimits`, `FreeMailDomains`, `PublicSuffixes`;
  `CommonWordList` with its scan algorithm. Tests including `CommonWordListTests` against the real
  asset. **Includes the required verification that `parakeet` is absent from the generated list**
  (arch §4) — if it is present, update the worked example in `functional_spec.md` §3.4.3, not the 3.0
  threshold. *(arch §2, §3.1–3.2, §3.10, §4)*

- [x] **Phase 2 — Extraction and assembly.**
  `CasingNormalizer`, `NameExtractor`, `CompanyExtractor`, `UncommonWordExtractor`,
  `VocabularyInputs`, `VocabularyAssembler`, `VocabularyService`. Full unit coverage. **Measure and
  record** the word-list file size, word count, and assembly time against a realistic full-length
  event description; escalate per arch §3.10 only if the target is missed. *(functional §3; arch
  §3.3–3.9, §7, §8. Depends on Phase 1.)*

- [x] **Phase 3 — Transcription wiring.**
  `TranscriptionService.init(store:engine:vocabulary:)`; compute the vocabulary once in `runJob` and
  thread it into both `runEngine` and `persistAndPromote`; update all 8 call sites including
  `AppCore.live`, `PreviewAppCore`, and `CoreFixture`. Assert the persisted `vocabularyUsed` matches
  what the engine received. *(functional §4; arch §5.1, §5.4. Depends on Phase 2.)*

- [x] **Phase 4 — Settings section and editor sheet.**
  `SettingsVocabularySection.swift`, `VocabularyListSheet.swift`, the view-model state, actions, and
  `VocabularyTermError` validation; `sectionTitles` insertion at index 1 and the re-index of every
  downstream reference and test. *(functional §5; ui_design §1–2; arch §5.2. Depends on Phase 1.)*

- [ ] **Phase 5 — Re-transcribe alert, plus doc reconciliation.**
  `MeetingDetailViewModel` gains the `Vocabulary` dependency and `shouldOfferReTranscribe()`; both
  `TODO(re-transcribe-prompt)` markers deleted; the view's alert un-suppressed. Then update the
  durable docs: `specs/architecture.md` component 13 (reword per arch §1), `specs/implementation_plan.md`
  Project 14 and the Project 8 blocker note, and `specs/projects/stage_c/implementation_plan.md`
  Phase 9 (no longer deferred). *(functional §6; ui_design §3; arch §1, §5.3. Depends on Phases 2, 3.)*
