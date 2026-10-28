---
status: complete
---

# Phase 10: Recording-Screen Drawer, Menu Command and Setting

## Overview

Build the live transcript's surfaces on the recording screen, on top of the phase 9 bubble list and the phase 8 service: the round toggle with its level meter, the expanded drawer (header, bubbles, footer), the find bar, the language menu, note-time links, the View menu command (⌘T), the Settings toggle, the model download offer, accessibility, and the contrast checks for text drawn on the drawer card.

The phase also closes the follow-ups that earlier phases left for it:

1. Typing dots never show on an incomplete tail, and a Stop in any phase marks the tails incomplete.
2. Turning live transcription on mid-recording records no false overflow gap at the start marker.
3. A language switch whose finish times out records the lost audio as a gap.
4. The forwarder backs off while an engine refuses chunks, and stops handing over audio when the engine's updates end during the finish.
5. The mic-side write-order test (a failing file sends no live copy).
6. The in-app download trigger, in the drawer and in Settings.
7. The focus probe treats a text view outside any table row as holding the swap (`!= 0`).

The first live start of a new build can sit in Starting for minutes while macOS compiles the model. The drawer shows that calmly: the spinner and "Starting" stay, and after 15 s the drawer body explains that the first start after an update can take a few minutes and that recording is not affected.

## Steps

1. **Package** (`Packages/BiscottiKit/Package.swift`):
   - `RecordingUI` adds `TranscriptUI`, `LiveTranscriptionService` and `LiveTranscriptModel`. `RecordingUITests` adds `LiveTranscriptionService`, `LiveTranscriptModel` and `TranscriptUI`.
   - `SettingsUI` and `SettingsUITests` add `LiveTranscriptionService`.
   - `AppShellUITests` adds `LiveTranscriptionService` and `LiveTranscriptModel`.

2. **TranscriptUI**:
   - `TranscriptItemBuilder.live`: `showsTypingDots` is true only for a non-empty tail that is not incomplete.
   - `TranscriptBubbleList`: a `rowPadding` parameter (default `Tokens.homeHorizontalPadding`) and a `bottomPadding` parameter for the last row (default 0), and an initializer without a header (`where Header == EmptyView`) that adds no header row. The drawer uses 16 pt and 12 pt.
   - Scroll to the current find match whenever the match changes, not only its index, so a new query that keeps index 0 still scrolls.
   - Focus probe: `table.row(for:) != 0`.

3. **Live service follow-ups** (`LiveTranscriptionService/LiveRecordingSession.swift`):
   - `finish()`: a Stop while not running (starting, restarting, switching language, unavailable) marks the tails incomplete before cancelling.
   - `restartWithCurrentLanguage()`: after applying the old engine's finals, `recordRestartGaps()`.
   - Forwarder: a refused chunk waits 10 ms, doubling to at most 160 ms, reset when a chunk is taken. `updatesEnded` during `.finishing` marks the engine lost; the forwarder then drops chunks instead of offering them, and the finish skips the engine's finish and marks the tails incomplete.

4. **Pump follow-up** (`LiveTranscriptionService/LivePumpCore.swift`): an overflow gap that starts before `discardBefore`, on a track with no audio yet, is treated like `.notStarted` leading silence.

5. **AudioCapture** (`MicCaptureSession`): an internal `makeFile` parameter (default `VPIOFileHelper.createExtAudioFile`) so a test can inject a file whose writes fail. The recordable `ac_*` manual-test steps are already `not-run`.

6. **Service model download**: remove the `TODO(phase 10)` on `downloadModel()`; the drawer and Settings call it.

7. **RecordingViewModel** (new `RecordingViewModel+Live.swift`):
   - Projections: `liveStatus`, `showsLiveTranscript` (status is not `.off`), `liveLevel`, `liveItems` (cached `TranscriptItemBuilder.live(..., labelStyle: .none)`, rebuilt only when rows, gaps or the start marker change), `isDrawerExpanded`, `liveLanguage`, `detectedLanguageName`, `revealTime` (a get/set over the service's reveal request), `liveStatusText`, `liveAccessibilityValue`, `liveModelState`, `languageChoices`, `languageMenuTitle`, `canCopyLiveTranscript`.
   - Actions: `toggleDrawer()`, `collapseDrawer()`, `setLanguage(_:)`, `copyLiveTranscript()` (through an injected pasteboard writer), `revealNoteInTranscript(_:)` (`reveal(atRecordingTime: note.timestamp + timelineOffset)`, which expands the drawer), `downloadLiveModel()`.
   - Static helpers: `statusText(for:)`, `accessibilityValue(for:)`, `languageChoices(for:locales:)`, `languageTitle(language:detectedName:)`.

8. **Views** (`RecordingUI/`):
   - `LevelMeter`: four 3 pt bars, 6 to 16 pt tall, sage while live; still at 50% opacity when paused; still `inkTertiary` when unavailable; a steady mid height with Reduce Motion. Reads only `liveLevel`, so the 12 Hz level redraws only the meter.
   - `LiveToggleButton`: a 44 pt slot holding the meter (or a small `ProgressView` while starting) and a 9 pt chevron. Collapsed, a `cardFill` circle with `cardStroke` and `cardShadow`, `neutralChip` on hover and 6% darker when pressed; expanded, no circle. Tooltip "Show transcript (⌘T)" / "Hide transcript (⌘T)", with the unavailable reason first when there is one. Accessibility label "Show transcript" / "Hide transcript", value the state.
   - `LiveTranscriptDrawer`: the card (`cardFill`, `cardStroke`, `cardShadow`, `drawerRadius`), a 44 pt header (search button, `TRANSCRIPT` kicker, copy button with a 1.5 s checkmark) or the find bar, the `TranscriptBubbleList` with `follow: .live`, and a 44 pt footer (a 44 pt slot under the toggle, status text in `monoMeta`, the language menu). With no bubbles the body shows a calm placeholder: the download panel when the model is missing, the slow-start note after 15 s of Starting, the reason when unavailable, otherwise "The transcript appears here as people speak." `.onExitCommand` closes find first, then collapses.
   - `DrawerFindBar`: field "Find in transcript", "n of m", previous, next, close. Return moves to the next match and Shift-Return to the previous one.
   - `LanguageMenu`: a `Menu` of checkable items with a title and a gray subtitle; its label is the "character.bubble" glyph, `languageMenuTitle` and a chevron.
   - `LiveModelDownloadPanel`: Download, progress with the stage message, or the failure with Try Again.
   - `LiveTranscriptOverlay`: a `ZStack(alignment: .bottomLeading)` constrained like the notes column (`maxWidth: 600`, `spacingXL` horizontal padding, `spacingMD` bottom padding). The drawer, when expanded, sits under the toggle, which never moves. Height `clamp(0.45 × height, 240, 520)`. Spring 0.25 s scale and opacity from the bottom-leading anchor; with Reduce Motion a 0.15 s cross-fade.
   - `RecordingView`: the overlay on the notes scroll view, hidden when live transcription is off, and `.contentMargins(.bottom, …)`: drawer height + 16 pt when expanded, 60 pt when collapsed, 0 when hidden.
   - `RecordingNotesView`: a note's time is a plain-style button (same font and color, "Show in transcript" help, pointing-hand cursor) calling `revealNoteInTranscript`, and plain text when live transcription is off.

9. **Menu command**:
   - `AppShellUI/LiveCommandModel.swift`: `@MainActor @Observable`, `nonisolated init(core: AppCore? = nil)`, `core` settable; `title` ("Hide Live Transcript" while the recording screen shows the open drawer, else "Show Live Transcript"), `isEnabled` (a recording runs and live transcription is not off; disabled when nothing is recording or live transcription is off, as `ui_design.md` says), `toggle()` (on the recording screen, toggles the drawer; on another screen, brings the recording screen forward with the drawer shown).
   - `App/Sources/LiveTranscriptCommands.swift`: `CommandGroup(after: .sidebar)` with a button view that reads the model in its `body`, `.keyboardShortcut("t", modifiers: .command)`. `AppDelegate` owns `liveCommandModel` and sets its core in `buildCore()`.

10. **Settings** (`SettingsUI`):
    - `SettingsViewModel`: `liveTranscriptEnabled` (resolved with an injectable `physicalMemory`), `setLiveTranscriptEnabled(_:)` (writes `liveTranscriptEnabled`, posts `.liveTranscriptEnabledDidChange`, reverts on failure), `liveModelState`, `downloadLiveModel()`.
    - `SettingsView`: `Toggle("Show live transcript while recording")` after "Stop Recording Automatically", no caption. While it is on and the model is not on disk, a row below it offers the download, shows its progress, or its failure with Try Again.

11. **Contrast** (`DesignSystemTests/TranscriptContrastTests.swift`): bubble text on both fills composited over `cardFill` (the drawer), markers and the drawer's status, find-count and placeholder text (`inkSecondaryLegible`) on `cardFill`, in both appearances. Adjust a token only if a check fails.

12. **Docs**: the research README's download follow-up says phase 10 added the drawer's and Settings' download.

## Tests

- `TranscriptItemBuilderTests.incompleteTailShowsNoTypingDots`: a tail marked incomplete keeps its text and shows no dots.
- `TranscriptContrastTests`: drawer bubble text and the drawer's secondary text reach 4.5:1 on `cardFill` in both appearances.
- `LivePumpTests` (or `LiveAudioPumpTests`) `overflowBeforeTheStartIsNotAGap`: an overflow block that starts before `discardBefore` on a silent track records no gap, and later audio is continuous.
- `LiveTranscriptionServiceTests`:
  - `stopDuringRestartMarksTailsIncomplete`
  - `languageSwitchTimeoutRecordsTheLostAudio`
  - `engineLostWhileFinishingEndsTheFinishEarly`: updates end during the finish; the finish returns well before the deadline with the tail marked incomplete.
  - `refusingEngineIsOfferedLessOften`: an engine that refuses chunks for 300 ms sees far fewer than 30 offers.
- `MicCaptureLiveCopyTests.failedWriteSendsNoLiveCopy`: a mic file that refuses writes leaves only the end block in the live queue.
- `RecordingViewModelTests` (new `RecordingViewModelLiveTests`):
  - `overlayHiddenWhenLiveOff`, `statusTextMatchesEachStatus`, `accessibilityValueNamesEachState`
  - `revealAddsTimelineOffsetToNoteTime`, `revealExpandsDrawer`
  - `copyLivePrefixesYouAndOthers`, `languageMenuShowsDetectedLanguage`, `languageMenuListsLocalesWhenEngineCannotDetect`
  - `liveItemsHaveNoLabelsAndAreCached`, `downloadFromDrawerStartsLive`
- `SettingsViewModelTests`: `liveTranscriptToggleWritesSettingAndPostsNotification`, `toggleShowsResolvedDefault`, `liveModelDownloadUpdatesState`.
- `LiveCommandModelTests`: `titleFlipsWithDrawerState`, `enabledWhileTheToggleShows`, `toggleFlipsTheDrawer`, `toggleOnAnotherScreenShowsTheRecording`.
- `AppCoreLiveTests.startRecordingStartsCaptureBeforeLiveSession`: the engine is created only after capture has started.
