---
status: complete
---

# Phase 3: Transcription Wiring

## Overview

Wire `VocabularyService` into `TranscriptionService` so each transcription job computes the
effective vocabulary once and threads the same array into both the engine call and the persistence
call. Update all call sites. The governing invariant: `vocabularyUsed` is byte-identical to what the
engine received, and vocabulary assembly failures never fail a transcription job.

## Steps

1. **Add `Vocabulary` dependency to `TranscriptionService` target** in `Package.swift`.
   `TranscriptionService` needs to import `Vocabulary` for the `VocabularyService` type.

2. **Add `Vocabulary` dependency to `AppCore` target** in `Package.swift`.
   `AppCore` constructs `VocabularyService(store:)` and injects it.

3. **Add `Vocabulary` dependency to `BiscottiTestSupport` target** in `Package.swift`.
   `CoreFixture` constructs `VocabularyService` for test cores.

4. **Modify `TranscriptionService.init`** to accept a `vocabulary: VocabularyService` parameter.
   Store it as `private let vocabulary: VocabularyService`.

5. **Modify `executeJob`** to compute vocabulary once before `runEngine`:
   ```swift
   let vocab = await vocabulary.effectiveVocabulary(meetingID: meetingID)
   ```
   Thread `vocab` into both `runEngine` and `persistAndPromote`.

6. **Modify `runEngine`** to accept `vocabulary: [String]` and pass it to `engine.processAudio`.

7. **Modify `persistAndPromote`** to accept `vocabularyUsed: [String]` and pass it to
   `store.addTranscript`.

8. **Update all 8 call sites** for `TranscriptionService(store:engine:)`:
   - `AppCore+Live.swift:56` -- construct `VocabularyService(store:)`, pass to init
   - `PreviewAppCore.swift:37` -- same pattern
   - `CoreFixture.swift:509` -- same pattern
   - `SettingsAIEnhancementsTests.swift:258` -- same pattern
   - `TranscriptionServiceTests.swift` lines 57, 360, 470, 728 -- same pattern

9. **Add `import Vocabulary`** to each file that constructs `VocabularyService`.

10. **Write tests** in `TranscriptionServiceTests.swift`:
    - Assert the fake engine receives the vocabulary computed by VocabularyService.
    - Assert persisted `vocabularyUsed` is byte-identical to what the engine received.
    - Assert vocabulary assembly failure does not fail the transcription job.

## Tests

- `testTranscribePassesVocabularyToEngine`: set up custom vocabulary terms in settings, run
  transcribe, assert `fakeEngine.backing.lastVocabulary` contains those terms.
- `testPersistedVocabularyMatchesEngineVocabulary`: after transcription, load the persisted
  transcript and verify `vocabularyUsed` exactly matches `fakeEngine.backing.lastVocabulary`.
- `testVocabularyDisabledSendsEmpty`: turn `customVocabularyEnabled` off, transcribe, assert
  engine received `[]` and persisted `vocabularyUsed` is `[]`.
- `testVocabularyAssemblyFailureDoesNotFailJob`: even if settings can't be read, the job still
  completes (vocabulary degrades to empty).
