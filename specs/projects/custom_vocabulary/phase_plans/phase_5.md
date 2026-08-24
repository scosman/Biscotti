---
status: complete
---

# Phase 5: Re-transcribe Alert + Doc Reconciliation

## Overview

Two parts: (1) wire the re-transcribe alert into MeetingDetailViewModel so that attaching or changing
a calendar association on a meeting with an existing transcript offers to re-run with updated
vocabulary, and (2) update the durable repo docs to reflect the completed custom-vocabulary feature.

## Steps

### Part 1 — Re-transcribe alert

1. **Package.swift** — add `"Vocabulary"` to the `MeetingDetailUI` target's dependency list, and to the
   `MeetingDetailUITests` target.

2. **MeetingDetailViewModel.swift** — add `import Vocabulary` and a stored
   `private let vocabulary: VocabularyService`, created in `init` from `core.store`:
   ```swift
   self.vocabulary = VocabularyService(store: core.store)
   ```

3. **MeetingDetailViewModel.swift** — delete the TODO(re-transcribe-prompt) comment block at line 58–60
   and update the doc comment on `showReTranscribeAfterCorrection`.

4. **MeetingDetailViewModel.swift** — delete the TODO(re-transcribe-prompt) comment block at line ~951
   in `correctAssociation(eventKey:)`, and replace it with the actual logic:
   ```swift
   if eventKey != nil {
       showReTranscribeAfterCorrection = await shouldOfferReTranscribe()
   }
   ```

5. **MeetingDetailViewModel.swift** — add `shouldOfferReTranscribe()` as a private method:
   ```swift
   private func shouldOfferReTranscribe() async -> Bool {
       guard let newest = versions.first else { return false }
       guard isAudioAvailable else { return false }
       guard let settings = try? await core.store.settings(),
             settings.customVocabularyEnabled,
             settings.calendarVocabularyEnabled else { return false }
       let recomputed = await vocabulary.effectiveVocabulary(meetingID: meetingID)
       return recomputed != newest.vocabularyUsed
   }
   ```

6. **MeetingDetailView.swift** — replace the inline `reTranscribePrompt` banner with a standard
   `.alert` modifier using the spec copy:
   - Title: "Re-transcribe with keywords from this event?"
   - Message: "We'll use this event's title, description and attendee list to improve transcription accuracy."
   - OK (default) → `reTranscribeAfterCorrection()`; Cancel (role: .cancel) → `dismissReTranscribePrompt()`.
   - Remove the `if viewModel.showReTranscribeAfterCorrection { reTranscribePrompt }` from `chrome`.
   - Remove the `reTranscribePrompt` computed property.

### Part 2 — Doc reconciliation

7. **specs/architecture.md** component 13 — reword to reflect that Vocabulary owns assembly,
   extraction, limits, and the word list, but NOT storage (storage stays in AppSettings).

8. **specs/implementation_plan.md** — update Project 14 to mark as complete/built, remove the Project 8
   blocker note about promptTokens.

9. **specs/projects/stage_c/implementation_plan.md** — update Phase 9 to remove the deferred/blocked
   note (the feature is built via the custom_vocabulary project).

10. **CLAUDE.md** — update the summary paragraph to reflect custom vocabulary as built.

## Tests

- `reTranscribeNotOfferedWithNoTranscript`: no versions loaded → flag stays false.
- `reTranscribeNotOfferedWithNoAudio`: meeting has transcript but no audio → flag stays false.
- `reTranscribeNotOfferedWhenCustomVocabDisabled`: master toggle off → flag stays false.
- `reTranscribeNotOfferedWhenCalendarVocabDisabled`: calendar toggle off → flag stays false.
- `reTranscribeNotOfferedWhenVocabularyUnchanged`: same vocabulary → flag stays false.
- `reTranscribeOfferedWhenVocabularyDiffers`: different vocabulary → flag becomes true.
- `reTranscribeNotOfferedOnRemoveAssociation`: removing association → flag stays false.
