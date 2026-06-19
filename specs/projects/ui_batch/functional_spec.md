---
status: complete
---

# Functional Spec: UI Batch

A batch of small, mostly-independent UI fixes to the Biscotti macOS app. Each item below is self-contained and maps to one implementation phase. "Current" describes today's behavior (from a code survey); "Desired" is the target; "Edge cases" and "Acceptance" pin down the details so each can be built autonomously.

All UI lives in `Packages/BiscottiKit/Sources/`. macOS 15+, Apple-silicon only, SwiftUI + AppKit glue.

---

## 1. Record button — one size bigger

**Current:** The idle top-right toolbar "Record" button (`AppShellView.swift`, ~line 89) uses `ToolbarRecordButtonStyle(fill: .sage)` (`DesignSystem/JoinRecordButtonStyle.swift`, ~line 45): 13pt medium text, 10pt horizontal / 4pt vertical padding, no `.controlSize`, no fixed height. It reads as small/cramped relative to its prominence.

**Desired:** Make the idle Record button one Apple control-size step taller/bigger — visually a notch more prominent, consistent with macOS control sizing. The recording-state button (`RecordingToolbarButton`, the red "REC m:ss") already has `.frame(height: 34)`; the idle Record button should feel like a peer to it in height, not noticeably shorter.

**Edge cases:**
- Don't introduce a jarring height change when the button swaps between idle "Record" and the recording "REC m:ss" state — they should be close in height so the toolbar doesn't jump.
- Keep the sage fill, label, and icon; this is a size change only.

**Acceptance:** The idle Record button is visibly taller/larger (one control-size step) and sits comfortably next to the search field without overpowering or looking cramped. Lint/tests green.

---

## 2. Reduce repeated "RECORDING" emphasis

The active-recording state is currently emphasized in **three** places in the main window simultaneously: (a) the top-right toolbar button (red pulsing "REC m:ss"), (b) the sidebar "RECORDING NOW" section with a red-tinted backdrop, and (c) the in-page "RECORDING" badge on the recording screen itself. That's too much. Two changes reduce the redundancy. **Two commits** (2a, 2b).

### 2a. Normalize the sidebar recording item (drop the red backdrop)

**Current:** `RecordingNowSection` (`AppShellView.swift`, ~line 446) renders a "RECORDING NOW" kicker header + a button with the meeting title and a red "Recording" subtitle, on an always-red-tinted background (`Tokens.recordingTintSoft` = signalRed @ 8% when unselected, `recordingTintStrong` @ 12% when selected) plus a red stroke overlay when selected. Normal sidebar rows (Home, Past Meetings, Settings) use `Tokens.accentWashStrong` (sage @ 14%) when selected and `Color.clear` otherwise, with no special tint.

**Desired:** Make the sidebar recording item look like a **normal sidebar item, all the time** (not just when off the recording screen):
- No red backdrop. Use the same selection treatment as other rows: `Tokens.accentWashStrong` when it's the active route (`route == .recording`), `Color.clear` otherwise.
- Remove the red stroke overlay.
- Drop the red color from the "Recording" subtitle — use the standard secondary text color (`Tokens.secondaryText` / `.inkSecondary`) like other subtitle/meta text. (Keep the subtitle text itself so the row still reads as the in-progress recording.)
- The "RECORDING NOW" section header may stay (it's already in the standard kicker style with secondary color) — keep it consistent with the "UPCOMING" header.

**Edge cases:**
- The row remains tappable and still navigates to the recording route.
- It still only appears while recording (`if viewModel.isRecording`).

**Acceptance:** While recording, the sidebar item visually matches other sidebar rows (no red fill/stroke), highlighting only with the standard sage wash when it is the active route.

### 2b. Disable the top-right button while on the recording page

**Current:** The Home toolbar button is `.disabled(viewModel.isHome)` (where `isHome` = `route == .home`) so it goes subtle when you're already home. The top-right recording control has no such treatment: while recording, it shows the active `RecordingToolbarButton` which navigates to `.recording` and stays fully emphasized even when you're already on the recording page.

**Desired:** Mirror the Home pattern — when the user is **on the recording page** (`route == .recording`), the top-right recording control becomes subtle/disabled (they can already see the recording icon/animation on the page; the toolbar button is redundant there). Add an `isOnRecordingPage` (or similarly named) computed property to `AppShellViewModel` (`route == .recording`) and apply `.disabled(...)` to the top-right recording control.

**Edge cases:**
- This applies to the recording-state control (`RecordingToolbarButton`) — the thing shown while recording. When disabled, it should read as subtle (standard SwiftUI disabled appearance), and tapping does nothing. The pulsing dot/animation may remain but in the disabled (dimmed) state, matching how the Home button looks disabled on Home.
- When NOT on the recording page (e.g., recording in the background while viewing Home/Meetings), the button stays enabled so the user can jump to the recording.
- The idle "Record" button (not recording) is unaffected by this item — there's no "recording page to be on" when nothing is recording. (Disabling it on `.recording` route is unnecessary because while recording the control is the REC button, not the idle Record button.)

**Acceptance:** Navigating to the recording page dims/disables the top-right REC button (like Home-on-Home); leaving the page re-enables it.

---

## 3. Move "See All" into the homepage meetings list as its last row

**Current:** `HomePastSection` (`HomeUI/HomeView.swift`, ~line 304) shows a "PAST MEETINGS" kicker header with a "See all" + chevron `Button` to its right (in the header `HStack`, ~lines 309–327). Below is `pastCard` — a white `.homeCard()` `VStack` of up to 3 `pastRow`s separated by `InsetDivider()`. Tapping "See all" calls `viewModel.showMeetings()` → routes to `.meetings`. The full count is available as `core.summaries.count`; recent rows are `core.summaries.prefix(3)`.

**Desired:** Remove "See all" from the header. Add it as the **last row of the card**, styled like a normal list row:
- An `InsetDivider()` after the last `pastRow`, then a "See All" row.
- Left: `Text("See All")`.
- Right (before the chevron): the **total meeting count** as grey secondary detail text (e.g. `Text("128").foregroundStyle(.inkSecondary)`), then the `chevron.right` icon — matching the visual grammar of the other rows (`"See All" ……… 128 ›`).
- The row is a `Button(.plain)` calling `viewModel.showMeetings()`, with padding/hit-area matching `pastRow`.
- Expose the count on `HomeViewModel` (e.g. `pastMeetingsCount` = `core.summaries.count`).

**Edge cases:**
- **Zero past meetings:** the empty "No recordings yet" card stands alone — no "See All" row (navigating to an empty list is pointless). Only show the "See All" row when the past-meetings card is shown (≥1 meeting).
- **1–3 meetings:** still show the "See All" row with the true total count (consistent grammar; it still routes to the full Past Meetings view with search). The count is the *total*, which may equal the number of rows shown.
- The header now contains only the "PAST MEETINGS" kicker label (no trailing button).

**Acceptance:** "See all" no longer appears beside the title; it's the bottom row of the card, left-labeled "See All" with the grey total count before the chevron, and it navigates to Past Meetings. Hidden when there are no past meetings.

---

## 4. Play links start playback (not just seek)

**Current:** Clicking a transcript timestamp (a `biscotti://seek?t=…` link, handled in `SelectableTranscriptView`'s `OpenURLAction` → `onSeek` → `viewModel.seek(to:)`) **only seeks** — `seek(to:)` (`MeetingDetailViewModel.swift`, ~line 360) sets `audioPlayer?.currentTime` and syncs state, preserving play/pause. The same applies to notes deep-links (`biscotti://meeting/{id}?time=…`), which route through `applyPendingJumpIfNeeded` → `applySeekIfReady` → `seek(to:)`. So clicking a link while paused leaves playback paused.

**Desired:** Revise to "start playing if it was paused." Clicking a transcript timestamp link **or** a notes `biscotti://…` timestamp deep-link should seek to the time **and**, if playback is currently paused, start playing. If already playing, keep playing (just seek).

**Implementation note:** Route the link/deep-link seek through a dedicated method (e.g. `seekAndPlay(to:)`) that seeks then starts playback (+ ticker) if not already playing, and wire the two `onSeek` closures (`MeetingDetailView.swift` ~lines 243, 573) and `applySeekIfReady` (~line 578) to it. Keep a pure `seek(to:)` available. There is **no playback scrubber/slider** that calls `seek(to:)` today, so this change affects only link-driven seeks — but using a dedicated method keeps the autoplay semantics explicit so a future scrubber doesn't accidentally inherit it.

**Edge cases:**
- Player not yet loaded (deep-link arriving before audio loads): the existing `pendingSeek` mechanism applies the seek once loaded — the autoplay should likewise take effect when the deferred seek is applied (`applySeekIfReady`).
- Clamp behavior is unchanged (deep-link path clamps to `[0, duration]`).
- If there is no audio to play (e.g. `audioPlayer == nil`), behavior is a no-op as today (don't crash).

**Acceptance:** Clicking a transcript timestamp or a notes timestamp link while paused jumps to the time and begins playing; clicking while playing jumps and continues playing.

---

## 5. Transcribing UI fixes

Two independent issues in the transcription progress UI. **Two commits** (5a, 5b).

### 5a. Don't show a "Downloading…model" phase when nothing is downloading

**Current:** `JobStatus` (`TranscriptionService/JobStatus.swift`) has `.downloadingModel(message:)` and `.transcribing`. `TranscriptionService.executeJob` sets `.downloadingModel(message: "Preparing…")` unconditionally at the start, then `downloadModels` drives `.downloadingModel` from engine status callbacks. The engine (`Transcription/InProcessTranscriptionEngine.swift`) emits `status("Downloading speech-to-text model")` / `status("Downloading speaker ID model")` **unconditionally** whenever its in-memory `whisperKit`/`speakerKit` is `nil` (always true after a `shutdown()` between runs) — even when the model files are already cached on disk and no real download happens. `MeetingDetailViewModel.displayState` maps `.downloadingModel` → `.processing("Transcribing…", subtitle: message)`. Net effect: every transcription shows a "Downloading…model" subtitle even when fully cached.

**Desired:** Only surface the "Downloading…model" phase/subtitle when a download is **actually needed/starting**. When models are already cached locally, show the general "Transcribing…" spinner with **no** download subtitle.

**Keep it simple — both of these are acceptable; pick the simpler/cleaner one:**
1. **Delay-gate:** don't show the "Downloading…model" subtitle until the download phase has been active for ~5s. A cache-hit load finishes well under that, so the subtitle never flashes; a genuine download (which takes much longer) still shows it after the short delay.
2. **Real-signal-gate:** only show the "Downloading…model" phase once a real download-progress signal fires (e.g. progress reported and < 1.0). Cache hits never emit one ⇒ plain "Transcribing…".

Do **not** build elaborate per-SDK disk-cache path detection for this — the two simple gates above are preferred. The hardcoded initial `.downloadingModel(message: "Preparing…")` in `executeJob` must likewise not flash when no download is occurring.

**Research sub-task (report findings; this is the user's main open question):** The user assumed the model-readiness/download *check* is instant. Investigate whether the current `ensureModelsDownloaded` → WhisperKit/SpeakerKit init path adds noticeable latency on a **cache hit** (does it do blocking disk/compile/network work before returning, even when nothing downloads?). This is a code-level investigation (read the engine + SDK behavior); empirical on-device timing needs a human/`test-ai` run (the agent can't run model tests). **If the check is slow**, evaluate migrating to an optimistic flow: *assume cached → attempt to load/transcribe directly → only fall into the download path if that fails/the model is absent*, which avoids paying a "check" cost on the common cached path. If the optimistic migration is small and clearly better, implement it; if it's larger/riskier, document the finding and recommend it as a follow-up rather than bloating this phase. Record the conclusion in the phase plan and surface it at the review phase.

**Edge cases:**
- First-ever run (model genuinely missing): the download phase must still appear (after the short delay, or on the real signal) with its progress/subtitle.
- Partial/interrupted prior download: treat as "needs download."
- Don't regress the first-run download UX in pursuit of hiding it on cache hits.

**Acceptance:** On a machine with the model already downloaded, starting a transcription shows "Transcribing…" with no "Downloading…model" text (no flash). On a fresh machine (no cache), the download phase still appears. Findings on the check-latency question are recorded.

### 5b. Improve the in-meeting transcribing layout

**Current:** While a meeting transcribes, `MeetingDetailView.centeredStatus(message:subtitle:)` (~line 550) wraps a `StatusRow` (`DesignSystem/StatusRow.swift`) in Spacer/Spacer and centers it. `StatusRow` is an `HStack(alignment: .top)` with a **small** `ProgressView().controlSize(.small)` on the left and a left-aligned `VStack` of message (`Tokens.metadataFont`, small) + optional subtitle (`.caption`). Because it's a centered HStack whose intrinsic width changes when the subtitle appears/disappears or changes length, the whole block **shifts horizontally**. Text is small and not truly centered.

**Desired:** A nicer centered transcribing state in the meeting view:
- **Bigger spinner** (e.g. `ProgressView().controlSize(.large)`, or a scaled spinner) — clearly larger than the small inline one.
- **Larger primary text** ("Transcribing…"), **center-aligned**.
- The **subtitle on its own centered line below** the primary text (a vertical, center-aligned stack: spinner, then "Transcribing…", then optional subtitle line) — so changing or adding/removing the subtitle changes only vertical content on a centered axis and **does not shift** the block horizontally.
- The whole thing remains vertically + horizontally centered in the available content area.

**Scope note:** This is about the in-meeting-view transcribing state specifically (the `.processing` branch of `transcriptTabContent`). The shared `StatusRow` is used elsewhere (e.g. completed/checkmark states); prefer adding a dedicated centered transcribing view for this case rather than changing `StatusRow`'s shared behavior — unless a `StatusRow` change is clearly safe for all call sites. Decide in the phase plan.

**Edge cases:**
- Subtitle present (download phase) vs absent (plain transcribing): both look good and the layout doesn't jump horizontally between them.
- Reduce-motion: the spinner is a standard indeterminate `ProgressView`, which respects system settings; no custom infinite animation needed.

**Acceptance:** The transcribing state shows a larger centered spinner with larger centered "Transcribing…" text, and the optional subtitle sits on its own centered line below; changing the subtitle doesn't cause a horizontal shift.

---

## 6. OS-wide ⌘⇧R to start a recording, with a settings toggle

**Current:** No global/OS-wide hotkey infrastructure exists. App-level shortcuts (⌘, ⌘F, ⌘Q) are SwiftUI `.keyboardShortcut` menu commands in `BiscottiApp.swift`. Recording is started programmatically via `AppCore.startRecording(eventKey:)`. Settings are a SwiftData `AppSettings` `@Model` (`DataStore/Models/AppSettings.swift`) read/written through `core.store.updateSettings { … }`; `SettingsView`/`SettingsViewModel` (`SettingsUI`) render the "General" section.

**Desired:** A **system-wide** keyboard shortcut **⌘⇧R** that starts a recording even when Biscotti isn't focused, plus a settings toggle to enable/disable it (**default ON**).

**Implementation decisions (confirmed):**
- **Mechanism: Carbon `RegisterEventHotKey`** behind a small, well-written **in-repo wrapper** (e.g. a `GlobalHotKey` type that registers the hotkey, installs a Carbon event handler, and invokes a Swift callback; unregisters on teardown). Chosen because it is truly OS-wide, **consumes** the keystroke, needs **no extra TCC/Accessibility permission**, and **adds no third-party dependency**.
- **Action:** firing the hotkey calls `AppCore.startRecording()` (same entry point as other UI). It should activate/bring the app appropriately consistent with how a recording start surfaces today.
- **Setting:** add `globalRecordShortcutEnabled: Bool` (default `true`) to `AppSettings`, surfaced as a toggle in `SettingsView`'s General section (with a clear label, e.g. "Global shortcut to start recording (⌘⇧R)"). Toggling registers/unregisters the hotkey live (follow the existing settings-change notification pattern used for e.g. exit-on-close).

**Edge cases:**
- **Already recording:** ⌘⇧R while a recording is in progress is a **no-op** (you can't start a second recording). Don't crash or double-start; mirror whatever guard `startRecording` already has.
- **Toggle off:** unregister the hotkey immediately; ⌘⇧R no longer does anything app-wide. Toggle back on re-registers.
- **App launch:** register on launch only if the setting is ON; honor the persisted value.
- **Onboarding/permission states:** starting a recording via the hotkey should behave the same as starting via the menu bar (it will request mic permission etc. through the normal `startRecording` path). No special-casing required beyond using the standard entry point.
- The wrapper must clean up (unregister handler/hotkey) to avoid leaks if re-registered.

**Acceptance:** With the setting ON (default), pressing ⌘⇧R anywhere starts a Biscotti recording; the Settings toggle turns it off/on live; no extra macOS permission prompt is introduced.

---

## 7. Meeting list multi-select + delete

**Current:** `MeetingListView` (`MeetingListUI`) is a single-select `List(selection: Binding<UUID?>)` bound to `AppCore.meetingsSelection: UUID?` via `MeetingListViewModel.selectedID: UUID?`. There's **no** delete affordance on the list (no delete key, swipe, or context menu) — deletion happens only from the meeting detail overflow menu (`MeetingDetailViewModel.requestDelete/confirmDelete` → `AppCore.deleteMeeting(meetingID:)`), which also computes a neighbor selection. `AppCore.deleteMeeting` handles **one** meeting (deletes audio files, then the DB row). The detail pane in `MeetingsSplitView` shows `MeetingDetailView` for the selected id, else a `ContentUnavailableView` ("No Meeting Selected").

**Desired:** Two capabilities. **Two commits** (7a, 7b).

### 7a. Multi-select with shift

- Migrate selection to a multi-select set: `AppCore.meetingsSelection: Set<UUID>` (and `MeetingListViewModel.selectedID` → a `Set<UUID>`), binding the `List(selection: Binding<Set<UUID>>)`. SwiftUI's set-selection gives shift-click range and ⌘-click toggle multi-select on macOS for free.
- Update all readers/writers of `meetingsSelection`: `selectFromList`, `select(_:)`, the `MeetingsSplitView` detail routing, `AppShellViewModel` accessors, `autoSelectTopResult` (sets a single-element selection), and the delete/neighbor logic.
- **Detail pane behavior (confirmed):** exactly **1** selected → show that meeting's `MeetingDetailView` (as today). **More than 1** selected → show an **"N meetings selected" placeholder** in the detail pane, designed like the existing none-selected `ContentUnavailableView` empty state (same visual grammar), **with a Delete button** on it (deletes the whole selection, via the same confirmation flow as 7b). Zero selected → the existing "No Meeting Selected" empty state.

**Edge cases:**
- Single-click still selects exactly one (replacing the set). Shift-click extends a range; ⌘-click toggles individual items — standard macOS list semantics from set-selection.
- Search mode results list uses the same selection set; `autoSelectTopResult` sets a single-element selection.
- Anywhere code assumed a single optional id (e.g. detail VM creation, neighbor-after-delete), adapt to "exactly one" semantics.

### 7b. Delete key + confirmation, with multi-delete

- Hook the **Delete key** on the meeting list (`.onDeleteCommand` or `onKeyPress(.delete)`) to delete the **current selection** (one or many).
- Show an **alert/confirmation** before deleting: singular vs plural copy (e.g. "Delete this meeting?" vs "Delete N meetings? This can't be undone."). Confirm performs the deletion; cancel aborts.
- The same confirmation + delete is triggered by the **Delete button** on the "N selected" placeholder (item 7a).
- Add a batch delete path (e.g. `AppCore.deleteMeetings(_ ids: Set<UUID>)`) — or loop the existing `deleteMeeting(meetingID:)` — that removes audio files + DB rows for all selected, then resolves a sensible post-delete selection (e.g. clear selection, or select a neighbor of the removed set using the existing `neighborID` logic adapted for sets).
- The existing single-delete from the meeting detail overflow menu continues to work unchanged.

**Edge cases:**
- Delete key with **empty selection**: no-op (no alert).
- After deleting, selection should land somewhere sane (cleared, or a neighbor) and the detail pane updates accordingly (empty state if cleared).
- Deleting the currently-open detail meeting must not leave a stale detail pane.
- Multi-delete should be resilient if one deletion fails (don't abort the whole batch silently — at minimum don't crash; surface/log per existing error handling).
- Confirm copy reflects the count.

**Acceptance:** Shift-click selects a range; the detail pane shows "N meetings selected" with a Delete button when >1 are selected; pressing Delete (or the placeholder's Delete button) prompts a confirmation and, on confirm, deletes all selected meetings (audio + records) and updates selection/detail. Single-select + single-delete still behave correctly, including the existing detail-menu delete.

---

## Cross-cutting

- **Manual-test staleness:** Item 5a touches `Packages/Transcription` (and the transcription service). Per the repo rule, mark Transcription manual tests `not-run` (`tx_*` recordable steps) in `ManualTestApp/Results/manual_test_results.json` when that package changes. No other item edits `Transcription` or `AudioCapture`.
- **Checks:** every phase must end green on `lint` + `test` (`build`/`build_app` as appropriate), run via the `hooks-mcp` tools.
- **No bundle ID / signing changes. No new third-party dependencies** (item 6 uses in-repo Carbon glue).
