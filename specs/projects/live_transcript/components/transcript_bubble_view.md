---
status: complete
---

# Component: Transcript Bubble View

## Purpose and scope

One bubble transcript view, in a new `TranscriptUI` module (L3a shared UI), used by the live drawer and by every meeting's Transcript tab. It replaces `TranscriptListView` and `TranscriptContent`, which move here from `MeetingDetailUI`.

Not in scope: the drawer chrome and toggle ([live_drawer](live_drawer.md)), data loading (view models).

## Public interface

```swift
public struct TranscriptItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case bubble(Bubble)
        case gap(duration: TimeInterval)              // "NOT TRANSCRIBED LIVE · 0:12"
        case startMarker(time: TimeInterval)          // "LIVE TRANSCRIPT STARTED AT 4:12"
    }
    public let id: String                             // stable: segment UUID, LiveRow UUID, or "gap-<time>"
    public let kind: Kind
}

public struct Bubble: Equatable, Sendable {
    public enum Side: Equatable, Sendable { case leading, trailing }
    public var side: Side
    public var label: RunLabel?                       // shown above the first bubble of a speaker run
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var settledText: String
    public var tailText: String                       // live only
    public var showsTypingDots: Bool
    public var speakerID: Int?                        // saved only; enables the mapping sheet
}

public struct RunLabel: Equatable, Sendable { public var name: String; public var colorKey: String; public var time: TimeInterval }

public enum TranscriptItemBuilder {
    public static func saved(segments: [SegmentData], names: [Int: String], colorKeys: [Int: String],
                             speakerPersons: [Int: UUID], currentUserPersonIDs: Set<UUID>) -> [TranscriptItem]
    public static func live(rows: [LiveRow], gaps: [LiveGap], startMarker: TimeInterval?,
                            labelStyle: LiveLabelStyle) -> [TranscriptItem]   // .none (drawer) or .youOthers (draft)
}

public struct TranscriptBubbleList<Header: View>: View {
    public init(items: [TranscriptItem],
                canSeek: Bool,
                follow: FollowMode,                   // .never (saved) or .live
                find: FindState?,                     // drawer only
                revealTime: Binding<TimeInterval?>,   // scroll here once, then set nil
                anchorTime: Binding<TimeInterval?>,   // reports the top visible time; used across a swap
                onSeek: @escaping (TimeInterval) -> Void,
                onSpeaker: @escaping (Int) -> Void,
                @ViewBuilder header: () -> Header)
}
```

`FindState` (`@Observable`) holds the query, the matches (`[(itemID, Range<String.Index>)]`) and the current index, and offers `next()`, `previous()` and `close()`.

## Building items

**Saved transcripts:**
- One bubble per segment.
- A label appears when the speaker differs from the previous segment's speaker.
- The side is `.trailing` when `speakerPersons[speakerID]` is in `currentUserPersonIDs`, otherwise `.leading`.
- Name and color key use today's logic: assigned person name, then `speakerLabel`; color key `person-<UUID>`, then `speaker-<id>`, then the label.
- Segments without a speaker ID are leading and have no clickable name.

**Live rows:**
- Mic rows are trailing; system and mixed rows are leading. Mixed rows never get a speaker label, a copy prefix or a spoken speaker name, in any label style.
- Rows and gaps are merged by start time.
- Touching or overlapping gaps, of either track and either silence, form one stretch. It becomes one marker, at its full length, only when the parts not marked silent total 5 s or more (`minimumGapMarker`). Silence is judged per 250 ms chunk, so a long stall over speech with pauses is recorded as alternating silent and spoken gaps. The marker reads "Not transcribed live · 0:12" with the tooltip "Recording continued. The saved transcript includes this part." (UI review, 25 October 2026.) A stretch whose parts not marked silent are all capture gaps reads "Audio paused while switching devices · 0:07" with the tooltip "Your microphone or speakers were switching; nothing was recorded here." (`GapCause.deviceSwitch`; chosen by the user in the hardware review, 25 October 2026): the recording is silent there too. A stretch that also holds possibly spoken audio the live path missed keeps "Not transcribed live", because the saved transcript has that part.
- `.none` gives no labels; `.youOthers` labels runs "You" (color key `you`, drawn in `sage`) and "Others".
- `showsTypingDots` is true for a row with non-empty `tailText`.
- `startMarker` adds a first item.

## Rendering

- **Built on `List`**, keeping today's performance rules (`TranscriptListView.swift:25-163`):
  - `ForEach(items)` is a direct child of `List`.
  - Each row is wrapped in `.equatable()` and compares only its `TranscriptItem`, highlight ranges and `canSeek`.
  - The header is never behind an equality guard.
  - `.listStyle(.plain)`, hidden separators and backgrounds, readable width.
- **Bubble:** `Text` with `AttributedString`. Settled runs use `ink`; the tail uses `inkSecondary`, plus a dotted underline when Differentiate Without Color is on; find highlights add a background attribute. The text has `.textSelection(.enabled)`, so selection works within one bubble. The bubble has a context menu with Copy. Typing dots are a separate small view after the text.
- **Label row:** the name is a button to `onSpeaker` when a speaker ID exists. The time is a button to `onSeek` when `canSeek`, otherwise plain text. Hovering a bubble shows a `play.fill` button after its run label when `canSeek`.

## Following and reading back

`FollowController` (`@Observable`, pure state, unit-tested) holds `isFollowing` and the newest item ID.

- **At bottom:** detected with `onScrollGeometryChange(for: Bool.self)`, where at bottom means `contentOffset.y + containerSize.height ≥ contentSize.height − 24`. Leaving the bottom by user scroll sets `isFollowing = false`; reaching it sets `true`.
- **New items while following:** `ScrollViewReader.scrollTo(newestID, anchor: .bottom)`, coalesced to the store's 4 Hz updates, without animation.
- **Return to live:** `ReturnToLiveButton` is shown when not following; clicking it scrolls to the bottom and sets `isFollowing`.
- **Find:** an open find bar sets `isFollowing = false`. Closing it restores following if the view is at the bottom, or if it was following when find opened (hardware review, 25 October 2026: closing find left the drawer parked at a match for the rest of the call). A reader who was reading back stays where they are.
- **Appearing:** for `appearanceSettle` (1 s) after the list appears, as when the drawer opens again, a following list that lands away from the bottom scrolls to the newest item again instead of stopping (hardware review, 25 October 2026: a reopened drawer landed at its first row with Return to live; confirmed fixed on hardware). A stop logs the offsets at `.notice`. Limits of this timing rule: a reader who scrolls up within the first second is pulled back to the bottom until the second ends, and a layout jump after it still stops following. `onScrollPhaseChange` would tell the reader's scrolls from layout without timing, but whether a macOS `List` reports scroll phases is not verified, so the hardware-confirmed rule stays.
- **Reveal during find:** a reveal (a note's time) while find is open keeps its place when find closes.
- **Reveal:** `revealTime` scrolls to the item whose interval contains it (`startTime ≤ t < endTime`), or else the nearest item before it; a time inside a gap goes to the gap marker. It uses `anchor: .top`, stops following, then clears the binding. While reading back, the held items first catch up with the latest (review fix, 26 October 2026): a note's time past the rows held on screen lands on its own row, not on the last held one, and the list stays reading back there.
- **Reading back holds the view still:** while not following, the list keeps showing the items it had when following stopped, and new updates wait in the store. Return to live applies them and scrolls to the bottom. Nothing on screen moves or changes while reading back, even when two tracks insert rows in time order or a row above grows. Find and reveal also hold the view.

**Spike first:** `onScrollGeometryChange` on a macOS `List` must report geometry while scrolling, with two tracks updating at once and during a draft-to-final swap, and the spike must confirm how the top visible item is measured. If it does not work, the fallback is the same view built on `ScrollView` + `LazyVStack` with `.scrollPosition(id:)`, which loses row recycling. In that case the fallback is used only for the drawer, whose list is shorter, and the Transcript tab keeps `List` with `follow: .never`.

## Draft-to-final swap (Transcript tab)

- `anchorTime` reports the start time of the topmost visible item, tracked with `onAppear` and `onDisappear` of rows.
- The final transcript is saved as soon as it is ready; only the visible swap can wait.
- The swap waits while keyboard focus is inside the transcript list, because a selected bubble keeps focus after mouse-up and during keyboard selection. A small `NSViewRepresentable` probe in the list's background finds the enclosing scroll view; the list has focus when the window's first responder is a descendant of it. The swap happens when focus leaves the list, or when the tab is shown again.
- After the swap, `revealTime` is set to the saved anchor time, so the reader lands on the bubble containing it.

## MeetingDetailUI changes

- The transcript path uses `TranscriptBubbleList(items: TranscriptItemBuilder.saved(...))`. `MeetingDetailViewModel` loads `currentUserPersonIDs` once with the detail data.
- **New display state `.draft(LiveTranscriptSnapshot)`:** used when no transcript exists yet and `core.liveTranscription.draft(for:)` is non-nil. It shows the draft items with `.youOthers` labels under the `StatusRow` "Draft · final transcript in progress".
- **`.queued(.waitingForRecording)`** shows the `StatusRow` "Waiting to finish until the current recording stops" (above the draft when there is one).
- Copy, the version picker, the processing, failed and empty states, and the speaker sheet are unchanged.

## Dependencies

- Depends on: `DesignSystem`, `DataStore`, `Formatting`, `LiveTranscriptModel` (row types only; never an engine).
- Used by: `RecordingUI`, `MeetingDetailUI`.

## Test plan

`TranscriptItemBuilderTests`:
- `savedLabelsOnlyAtSpeakerChange`
- `savedSideIsTrailingForCurrentUserPerson`
- `savedSideIsLeadingWhenPersonUnknown`
- `segmentWithoutSpeakerIsLeadingWithoutAction`
- `liveMicRowsAreTrailingSystemLeading`
- `liveDrawerHasNoLabels`, `draftLabelsYouAndOthers`
- `gapsAndStartMarkerMergeInTimeOrder`
- `mixedRowsNameNoSpeakerInAnyStyle`
- `itemIDsAreStableAcrossTailUpdates`

`FollowControllerTests`:
- `scrollingUpStopsFollowing`, `reachingBottomResumesFollowing`
- `openingFindStopsFollowing`, `revealStopsFollowingAndClears`
- `revealLandsOnTheContainingBubble`, `revealInsideAGapGoesToTheGapMarker`
- `readingBackHoldsItemsUntilReturnToLive`

`FindStateTests`:
- `findsMatchesCaseAndDiacriticInsensitive`, `nextWrapsAround`, `countFormatsAsOneOfN`, `closeClearsHighlights`

`BubbleRowEquatableTests`: `equalItemsSkipRerender`, `tailChangeRerendersOnlyThatRow`.

`MeetingDetailViewModelTests` additions:
- `showsDraftWhileFinalPassRuns`, `swapsToFinalWhenSaved`
- `swapWaitsWhileTheListHasFocus`, `finalIsSavedBeforeTheVisibleSwap`
- `waitingStatusWhileRecording`, `savedTranscriptUsesCurrentUserSide`

The `List` spike is a short test-app experiment recorded in the phase plan, not a unit test.
