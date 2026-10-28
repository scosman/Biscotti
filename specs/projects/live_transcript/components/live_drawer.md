---
status: complete
---

# Component: Live Drawer, Menu Command and Setting

## Purpose and scope

The recording-screen surfaces from [ui_design.md](../ui_design.md):

- the round toggle and the expanded drawer,
- the find bar and language menu,
- note-time links,
- the View menu command,
- the Settings toggle.

Not in scope: the transcript list ([transcript_bubble_view](transcript_bubble_view.md)) and the service state ([live_transcription_service](live_transcription_service.md)).

## Views (`RecordingUI`)

| View | Role |
|---|---|
| `LiveTranscriptOverlay` | Placed over `recordingContent`; shows the collapsed toggle or the expanded drawer; hidden when `status == .off` |
| `LiveToggleButton` | The 44 pt circle (collapsed) or the footer toggle (expanded): waveform `LevelMeter` or spinner, chevron, tooltip |
| `LevelMeter` | Four bars driven by `service.level`; still bars when unavailable, paused or with Reduce Motion |
| `LiveTranscriptDrawer` | The card: header (search, kicker, "Catching up…" while behind, copy, and a collapse button added in the hardware review), `TranscriptBubbleList` with `follow: .live`, footer (toggle, status text, language menu) |
| `DrawerResizeHandle` | The card's top edge: drag to change the height, double-click to restore the default, VoiceOver adjusts it (second UI review, 25 October 2026) |
| `DrawerFindBar` | Field, "n of m", previous, next, close; drives `FindState` |
| `LanguageMenu` | `Menu` with "English" / "Best quality" and "Detect language" / "Finds the language once, then keeps it"; the label shows the detected language once known |

## Placement in `RecordingView`

Changed in UI review on 25 October 2026, when the user chose a wider drawer and notes that move up (see [ui_design](../ui_design.md#changes-from-ui-review-25-october-2026)).

- **Overlay:** `.overlay(alignment: .bottom)` on the `ScrollView` in `recordingContent`. `LiveTranscriptOverlay` spans the window less `Tokens.spacingMD` (16 pt) on each side, at most 880 pt (`drawerWidth(forAvailableWidth:)`), centered, with 16 pt of bottom padding. The drawer card fills it; the toggle sits `LiveTranscriptDrawer.outset` (12 pt) inside the card's leading edge, collapsed or open, so it never moves.
- **Bubble width:** the drawer's `TranscriptBubbleList` passes `maxRowWidth: .infinity`, so its rows use the whole card instead of the page's 760 pt readable width; bubbles keep the 75% rule.
- **Insets:** the `ScrollView` gets `.contentMargins(.bottom, inset, for: .scrollContent)`, where inset is the drawer height + 16 pt when expanded and 60 pt when collapsed.
- **Notes move up:** `RecordingNotesView` reports the note field's bottom edge, and `RecordingView` the column's first row's top, in the scroll content (`RecordingView.contentSpace`). While the drawer is open, a `ScrollPosition` scrolls the notes up by `LiveTranscriptOverlay.openLayout(viewportHeight:headerTop:noteFieldBottom:)`: the note field's bottom sits 16 pt above the drawer, and the header scrolls up with it, but the column's first row (the status row with Stop & Save, or the auto-stop card) stays at least 16 pt below the top. Closing the drawer scrolls back to the top. The scroll follows the drawer's motion, and runs again when the window's size changes. The column stays centered as before.
- **Drawer height:** `clamp(0.45 × geometry.size.height, 240, 520)`, then shrunk, to no less than 240 pt, until the column's first row, the note field and the drawer fit. If they still do not, the drawer covers the note field.
- **Height handle** (chosen by the user in the second UI review, 25 October 2026): `DrawerResizeHandle` lies over the card's top edge, 8 pt tall, with `.pointerStyle(.frameResize(position: .top))` and a 36 × 4 pt grabber that shows on hover and while dragging. Dragging up makes the drawer taller; the height follows the pointer (`RecordingView`'s `drawerDragHeight`) and is saved at the end, in whole points, as `LiveTranscriptionService.drawerHeight` (UserDefaults `liveTranscript.drawerHeight`), so it carries over to the next meeting. `openLayout(..., firstRowsHeight:, preferredHeight:)` keeps a chosen height between 240 pt and `maximumDrawerHeight(viewportHeight:firstRowsHeight:)`: the viewport less the 16 pt gutter, the 16 pt gap, the column's first rows (measured from the column's top to the status row's bottom) and the 16 pt top margin. So Stop & Save, and the auto-stop card, stay in view; a tall drawer may cover the note field. The notes' offset follows the height. Double-click restores the default (`resetLiveDrawerHeight()`, which removes the stored height). VoiceOver: label "Transcript height", value in points, adjustable in 40 pt steps, and a "Restore default height" action.
- **Notes scroll key:** the scroll follows `NotesScrollKey(offset:isDrawerOpen:)`, so opening the drawer re-applies the offset after the notes were scrolled, even when the offset is unchanged (round 1 follow-up). While dragging, the notes move without animation.
- **Drawer width:** `LiveTranscriptOverlay.drawerWidth(forAvailableWidth: geometry.size.width)`.
- **Motion:** `.spring(duration: 0.25)` scale and opacity from the toggle's bottom-leading anchor; with Reduce Motion, `.easeInOut(duration: 0.15)` opacity only (`LiveTranscriptOverlay.motion(reduceMotion:)`).
- **Esc:** `.onExitCommand` on the drawer closes the find bar first, then collapses the drawer.

## View model (`RecordingViewModel` additions)

- **Projections:** `liveStatus`, `liveLevel`, `liveItems` (built with `TranscriptItemBuilder.live(..., labelStyle: .none)`), `isDrawerExpanded`, `liveLanguage`, `detectedLanguageName`, `revealTime`.
- **Actions:** `toggleDrawer()`, `setLanguage(_:)`, `copyLiveTranscript()` (lines prefixed "You:" or "Others:"; mixed rows have no prefix), and `revealNoteInTranscript(_ note:)`, which calls `reveal(atRecordingTime: note.timestamp + state.timelineOffset)` and expands the drawer.
- **Slow start** (chosen by the user on 25 October 2026): after 10 s of Starting (`slowStartDelay`, was 15 s), the placeholder shows `slowStartMessages(lowOnDisk:)`; the disk is read once then (`checkDiskSpaceForSlowStart`, through `TranscriptionService.refreshDiskSpace`). See [ui_design](../ui_design.md#changes-from-the-second-ui-review-25-october-2026) for the copy.
- **Status text:** "Starting", "Paused while the Mac cools down", or the unavailable reason ("Needs the transcription model", "Not available for this language", "Live transcript stopped"). Live shows none. Since the second UI review (25 October 2026), Catching up shows in the header instead: "Catching up…" with a mini spinner after the `TRANSCRIPT` kicker while `isLiveCatchingUp`.
- **Height:** `liveDrawerHeight`, `setLiveDrawerHeight(_:)` (rounded to whole points) and `resetLiveDrawerHeight()`.
- **Gap markers** (hardware review, 25 October 2026): a stretch made only of capture gaps shows the device-switch marker, "Audio paused while switching devices · 0:07" ([transcript_bubble_view](transcript_bubble_view.md)); closing find returns to live when the drawer was following when it opened.
- **Reopening** (hardware review): the drawer's list keeps following through its first second of layout (`FollowController.appearanceSettle`). Known limit: a scroll up within that second is pulled back to the bottom, and a layout jump after it still stops following; see [transcript_bubble_view](transcript_bubble_view.md#following-and-reading-back).
- **Drawn rows** (phase 11): `liveRowsRevision` and `liveRowsDrawn()`. The drawer's body calls `liveRowsDrawn()` on the next main-queue turn after the revision changes, for the latency signposts ([live_transcription_service](live_transcription_service.md#in-app-latency-phase-11)).

## Note-time links (`RecordingNotesView`)

The note's time `Text` becomes a `Button` with `.buttonStyle(.plain)`, the same font and color, the help tag "Show in transcript" and the pointing-hand cursor on hover. It calls `viewModel.revealNoteInTranscript(note)`. It is plain text when live transcription is off.

## View menu command (`App`)

- `LiveTranscriptCommands: Commands`, added to the scene's `.commands`, with `CommandGroup(after: .sidebar)`.
- Its `@Observable LiveCommandModel` is owned by the app delegate and reads `core?.liveTranscription` and `core?.recording.state`.
- **Title:** "Hide Live Transcript" while the recording screen shows the open drawer, otherwise "Show Live Transcript". While nothing is recording, the disabled item reads "Show Live Transcript".
- **Shortcut:** `.keyboardShortcut("t", modifiers: .command)`.
- **Disabled:** when nothing is recording or live transcription is off, as `ui_design.md` says. It stays enabled while live transcription is unavailable, when the toggle still shows and the drawer offers the model download.
- **Action:** on the recording screen, `core.liveTranscription.toggleDrawer()`. On another screen during a recording, it brings the recording screen forward with the drawer shown.

## Settings toggle (`SettingsUI`)

- In the General section, after "Stop Recording Automatically": `Toggle("Show live transcript while recording", isOn: liveTranscriptBinding)`.
- **Preparing:** while the toggle is on and the live model is among `core.transcription.modelsBeingPrepared` (`SettingsViewModel.isPreparingLiveTranscript`), a mini spinner and "Preparing live transcript…" show under the toggle in the caption style. Added in UI review on 25 October 2026, with the background preparation ([transcriber_worker](transcriber_worker.md#model-preparation)).
- **Binding:** the same pattern as `stopRecordingAutomatically`. `SettingsViewModel.setLiveTranscriptEnabled(_:)` writes `store.updateSettings` and posts `.liveTranscriptEnabledDidChange`; AppCore observes it and calls `liveTranscription.setEnabled`.
- The toggle shows the resolved value, so on 8 GiB Macs it starts off.

## AppCore additions

- `let liveTranscription: LiveTranscriptionService`, built in `AppCore+Live.swift` with the hosted `Transcriber` and the `LiveAudioTap` factory, and with fakes in `CoreFixture`.
- **Recording start and stop** follow [transcriber_worker § AppCore wiring](transcriber_worker.md#appcore-wiring). The tap is created per recording and passed through `RecordingController.start` to `AudioRecorder.start(paths:liveTap:)`.

## Accessibility

As specified in `ui_design.md`:

- **Toggle:** `accessibilityLabel` "Show transcript" or "Hide transcript", `accessibilityValue` the status.
- **Live updates:** the drawer posts no announcements.
- **Keyboard:** Tab order puts the drawer after the note field.

## Dependencies

- Depends on: `TranscriptUI`, `LiveTranscriptionService` (through `AppCore`), `DesignSystem`.
- Used by: `AppShellUI` (hosts `RecordingView`), `App` (commands).

## Test plan

`RecordingViewModelLiveTests` (UI review, 25 October 2026): `drawerWidthSpansWindowUpTo880`, `notesMoveUpToKeepTheNoteFieldAboveTheDrawer`, `openLayoutWithRoomKeepsTheDrawerHeight`, `openLayoutShrinksTheDrawerToKeepStopAndSaveInView`, `openLayoutKeepsStopAndSaveInViewInAShortWindow`. `SettingsLiveTranscriptTests`: `preparingCaptionShowsWhileLiveIsOn`.

Second UI review (25 October 2026): `chosenHeightStaysWithinLimits`, `chosenHeightSavesAndResets`, `headerShowsCatchingUp`, `slowStartCountsFromStartingBegan` (10 s), `slowStartMessagesFollowTheDisk` in `RecordingViewModelLiveTests`; `drawerHeightPersists` in `LiveTranscriptionServiceTests`; `lowDiskWarningShowsWhileTheDiskIsLow` in `SettingsLiveTranscriptTests`.

`RecordingViewModelTests` additions:
- `overlayHiddenWhenLiveOff`, `statusTextMatchesEachStatus`
- `revealAddsTimelineOffsetToNoteTime`, `revealExpandsDrawer`
- `copyLivePrefixesYouAndOthers`, `languageMenuShowsDetectedLanguage`
- `languageMenuListsLocalesWhenEngineCannotDetect`

`SettingsViewModelTests`: `liveTranscriptToggleWritesSettingAndPostsNotification`, `toggleShowsResolvedDefault`.

`LiveCommandModelTests`: `titleFlipsWithDrawerState`, `enabledWhileTheToggleShows`, `toggleOnAnotherScreenShowsTheRecording`.

`AppCoreTests`:
- `startRecordingStartsCaptureBeforeLiveSession`
- `stopRecordingFinishesLiveThenQueuesFinalPass`
- `settingChangeMidRecordingStartsOrStopsLive`

Visual checks against the mockups in light and dark mode are part of the phase's manual review in a test build. Since the UI review of 25 October 2026, opening the drawer moves the notes up, as the mockups showed the header moving up, and the drawer is wider than the mockups' notes column.
