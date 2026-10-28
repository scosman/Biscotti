---
status: complete
---

# Phase 9: TranscriptUI and the Transcript Tab

## Overview

Build the shared bubble transcript view in a new `TranscriptUI` module and switch every meeting's Transcript tab to it. Saved transcripts become conversation bubbles: speakers tagged as the current user sit on the right as "You", everyone else on the left with their name and color. The view also carries what the live drawer (phase 10) needs: live item building, following and holding still, find, reveal and Return to live.

This phase runs before phases 7 and 8. Phase 8 provides `core.liveTranscription.draft(for:)` and phase 7 the `.queued(.waitingForRecording)` job status. So `MeetingDetailViewModel` reads drafts and the waiting state from an injected `LiveDraftSource` (closures), tested with a fake. AppCore wiring waits for phase 8 (`TODO(phase 8)`). With no source, saved meetings behave exactly as before, apart from the new bubble rendering. `DataStore.currentUserPersonIDs()` (listed under phase 8) is built here, because saved transcripts need it to place "You".

## List spike outcome

A throwaway AppKit-hosted SwiftUI app (macOS 26.6, Xcode 26.3, outside the repository) drove a plain `List` of 200 bubble rows with a header row through scripted steps:

- **The `List` is an NSTableView** (`ListCoreScrollView` holding `SwiftUIOutlineListView`), and `onScrollGeometryChange` works on it: one callback per mouse-wheel step (10 of 10), callbacks while two tracks grew and inserted rows at 4 Hz (14 in 16 ticks), and callbacks after a full item replacement.
- **Following:** `ScrollViewReader.scrollTo(newestID, anchor: .bottom)` after each update kept the view at the bottom through both tracks updating and a row inserted above the newest one (at-bottom never went false).
- **Content growth alone flips at-bottom to false** with an unchanged content offset. So "the user left the bottom" must mean the offset moved up, not only that at-bottom became false.
- **`onScrollPhaseChange` reported nothing** for wheel or synthesized trackpad events on this `List`, so following does not use scroll phases.
- **Top visible item:** `onAppear`/`onDisappear` overscan: the first appeared row was one to two rows above the top visible row. Per-row `onGeometryChange` with `frame(in: .scrollView)` matched the table's own visible rows within one row (the half-visible rule). The view measures the top visible item with per-row geometry, not appearance.
- **Draft-to-final swap:** replacing all items, then `scrollTo(itemContainingAnchor, anchor: .top)`, put that item exactly at the top; scroll geometry kept reporting afterwards.
- **Focus probe:** a click and drag in a `.textSelection(.enabled)` bubble made an `NSTextView` the window's first responder. It is a descendant of the list's `NSScrollView`, which the probe (in the list's background) finds by searching its ancestors' subtrees for a scroll view that overlaps it. KVO on `NSWindow.firstResponder` reported each change; resigning reported false.

Result: `List` works for both the drawer and the tab. The `ScrollView` + `LazyVStack` fallback is not needed.

## Spec contradiction resolved

`ui_design.md` names `Color.inkSecondary` for the unsettled tail and also requires 4.5:1 for every bubble's text on both fills. Light `inkSecondary` (ink at 54%) reaches only 3.6:1 on `neutralChip` and `softSageFill`. A new token, `Color.inkSecondaryLegible` (ink at 62% in light mode, the faintest that keeps 4.6:1 on both fills; `inkSecondary`'s 58% in dark mode, which passes), is used for the tail and for gap and start markers. `TranscriptContrastTests` checks each text token against each bubble fill, and the marker token against `paper`, in both appearances.

## Steps

1. **Package** (`Packages/BiscottiKit/Package.swift`): new target and product `TranscriptUI` (depends on `DesignSystem`, `DataStore`, `Formatting`, `LiveTranscriptModel`) and test target `TranscriptUITests`. `MeetingDetailUI` and `MeetingDetailUITests` add `TranscriptUI` and `LiveTranscriptModel`.

2. **DataStore** (new `DataStore+CurrentUser.swift`): `func currentUserPersonIDs() throws -> Set<UUID>`: the distinct non-nil `CalendarSnapshot.currentUserPersonID` values.

3. **Design tokens** (`DesignSystem/Tokens.swift`): `bubbleRadius = 14`, `drawerRadius = 16`. `StatusRow` gains `Style` (`.standard`, `.caption`); `.caption` uses `Font.monoCaption`, uppercase, tracked, `inkSecondary`, with a mini spinner.

4. **Items** (`TranscriptUI/TranscriptItem.swift`):
   - `TranscriptItem` (`id`, `kind`), `Kind`: `.bubble(Bubble)`, `.gap(startTime:duration:)`, `.startMarker(time:)`; `timeRange` for reveal.
   - `Bubble` as in the component, plus `spokenName: String?` for VoiceOver (nil for mixed rows). `RunLabel(name:colorKey:time:)` with reserved keys `you` (drawn in `sage`) and `others` (`inkSecondary`).
   - `LiveLabelStyle`: `.none`, `.youOthers`. `FollowMode`: `.never`, `.live`.

5. **Builders** (`TranscriptUI/TranscriptItemBuilder.swift`):
   - `saved(segments:names:colorKeys:speakerPersons:currentUserPersonIDs:)`: one bubble per segment, label at each speaker change, trailing for current-user persons, named "You" with key `you` (the functional spec and ui_design show "You · 0:38" on the right). Other names and keys follow today's logic.
   - `live(rows:gaps:startMarker:labelStyle:)`: rows without text are skipped; mic trailing, system and mixed leading; overlapping gaps from both tracks merge into one marker; rows and markers are merged by start time; `.youOthers` labels runs "You"/"Others" and a marker ends a run; mixed rows never get a label or spoken name; tail rows show typing dots.
   - `TranscriptContent` (speaker colors) moves here from `MeetingDetailUI`, with `colorKey` resolution shared by both.

6. **Following** (`TranscriptUI/FollowController.swift`, `@MainActor @Observable`, pure state):
   - `ScrollSample(offsetY:contentHeight:containerHeight:)` with `isAtBottom` (within 24 pt).
   - `isFollowing`, `heldItems`, `scrollRequest` (target ID, anchor, token).
   - `scrollChanged(_:latest:)`: at bottom resumes following (unless find is open); leaving the bottom stops following only when the offset moved up.
   - `itemsChanged(_:)` requests the newest item at `.bottom` while following. `returnToLive(latest:)`, `findOpened(latest:)`, `findClosed(latest:)`, `reveal(time:in:)`.
   - `static func revealTarget(for:in:)`: the item whose range contains the time, else the nearest one before, else the first.

7. **Find** (`TranscriptUI/FindState.swift`, `@MainActor @Observable`): `query`, `isOpen`, `matches: [FindMatch]` (`itemID`, `Range<String.Index>` in the bubble's full text), `currentIndex`, `update(items:)`, `next()`, `previous()`, `close()`, `countText` ("2 of 5"), `highlights(for:)`. Case- and diacritic-insensitive.

8. **Views** (`TranscriptUI/`):
   - `TranscriptBubbleList` with the component's initializer plus `onFocusChange: ((Bool) -> Void)?` (installs the focus probe) and `onSpeakerDebug: ((Int) -> Void)?` (today's DEBUG voiceprint menu). `List` with the header row, then `ForEach(displayedItems)` of `TranscriptItemRow(...).equatable()`; per-row `onGeometryChange` feeds a `VisibleRowTracker` that writes `anchorTime` (nil while the header is visible); `onScrollGeometryChange` feeds the follow controller in `.live`; `ReturnToLiveButton` overlay; reveal and current find match scroll through `ScrollViewReader`.
   - `TranscriptItemRow` (`Equatable` on item, highlights, `canSeek`): bubble, gap marker or start marker.
   - `BubbleView`: `AttributedString` with settled (`ink`) and tail (`inkSecondary`, dotted underline with Differentiate Without Color) runs and find backgrounds; `.textSelection(.enabled)`; Copy context menu; 75% width layout; fills `neutralChip` / `softSageFill`; `TypingDots` after the text.
   - `RunLabelView`: name button (`onSpeaker` when a speaker ID exists), time button (`onSeek` when `canSeek`), play button on hover.
   - `TypingDots`, `GapMarker`, `StartMarker`, `ReturnToLiveButton`, `TranscriptFocusProbe`.

9. **MeetingDetailUI**:
   - `LiveDraftSource` (closures: `draft(for:)`, `isWaitingForRecording(_:)`, static `.none`); `MeetingDetailViewModel.init(..., liveDrafts: LiveDraftSource = .none)` with `TODO(phase 8)` to read `core.liveTranscription` and the phase 7 job status.
   - `MeetingDetailState` gains `.draft(LiveTranscriptSnapshot, DraftStatus)` (`.finalPassInProgress`, `.waitingForRecording`, `.finalPassFailed(message:retriable:)`) and `.waitingForRecording`.
   - View model: `currentUserPersonIDs` loaded in `refreshData`; `shownDraft` kept until the visible swap; `syncDraft()`; `setTranscriptListFocused(_:)`; `transcriptTabShown()`; swap sets `transcriptRevealTime` to `draftAnchorTime`; cached `transcriptItems` and `draftItems`.
   - View: the list layout covers `.transcript` with segments and every `.draft`; one `TranscriptBubbleList` for both, with the draft `StatusRow` (or the failure banner) in the header; `.waitingForRecording` shows a `StatusRow` in the scroll path; `onChange` hooks for the draft source, focus and tab.
   - Remove `TranscriptListView.swift` and `TranscriptContent.swift` from `MeetingDetailUI`; `SpeakerMappingSheet` imports `TranscriptUI`.

## Tests

`DataStoreTests`:
- `currentUserPersonIDsCollectsDistinctIDs`

`TranscriptItemBuilderTests`:
- `savedLabelsOnlyAtSpeakerChange`, `savedSideIsTrailingForCurrentUserPerson`, `savedSideIsLeadingWhenPersonUnknown`, `segmentWithoutSpeakerIsLeadingWithoutAction`, `savedNamesAndColorKeysFollowAssignments`
- `liveMicRowsAreTrailingSystemLeading`, `liveDrawerHasNoLabels`, `draftLabelsYouAndOthers`, `gapsAndStartMarkerMergeInTimeOrder`, `overlappingGapsMergeIntoOneMarker`, `mixedRowsNameNoSpeakerInAnyStyle`, `itemIDsAreStableAcrossTailUpdates`, `rowsWithoutTextAreSkipped`

`FollowControllerTests`:
- `scrollingUpStopsFollowing`, `reachingBottomResumesFollowing`, `contentGrowthKeepsFollowing`
- `openingFindStopsFollowing`, `closingFindAtBottomResumesFollowing`
- `revealStopsFollowingAndClears`, `revealLandsOnTheContainingBubble`, `revealInsideAGapGoesToTheGapMarker`
- `readingBackHoldsItemsUntilReturnToLive`, `newItemsWhileFollowingRequestTheNewest`, `neverModeDoesNotHold`

`FindStateTests`:
- `findsMatchesCaseAndDiacriticInsensitive`, `nextWrapsAround`, `countFormatsAsOneOfN`, `closeClearsHighlights`, `updateKeepsCurrentMatchWhenItStillExists`

`BubbleRowEquatableTests`: `equalItemsSkipRerender`, `tailChangeRerendersOnlyThatRow`, `highlightOrCanSeekChangeRerenders`

`VisibleRowTrackerTests`: `topVisibleIsFirstRowWhoseMiddleIsOnScreen`, `headerVisibleGivesNoAnchor`

`TranscriptContentTests` and the speaker-color tests move to `TranscriptUITests`; `TranscriptListViewTests` is replaced by `BubbleRowEquatableTests`.

`MeetingDetailViewModelTests` additions (fake `LiveDraftSource`):
- `showsDraftWhileFinalPassRuns`, `swapsToFinalWhenSaved`, `swapWaitsWhileTheListHasFocus`, `finalIsSavedBeforeTheVisibleSwap`, `swapRevealsTheAnchorTime`
- `waitingStatusWhileRecording`, `waitingWithoutDraft`, `failedFinalPassKeepsDraft`
- `savedTranscriptUsesCurrentUserSide`, `noLiveSourceShowsSavedTranscript`
