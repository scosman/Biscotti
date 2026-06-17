---
status: complete
---

# Architecture: Record Screen Redesign

Technical design for the recording pane, its chrome, the in-memory notes +
markdown seeding, and the `biscotti://meeting` deep link. Behavior is in
`functional_spec.md`; visuals in `ui_design.md`.

**Organization:** single architecture doc (no `/components`). The work spans
several existing BiscottiKit modules plus the App target, but each piece is
moderate.

**Module placement**

| Concern | Home |
|---|---|
| Shared editable-title control | `DesignSystem` (already imports AppKit) |
| Recording pane view | `RecordingUI/RecordingView.swift` |
| Recording pane view model | `RecordingUI/RecordingViewModel.swift` |
| In-memory notes + seeding | `Recording` (`RecordingController`, new `MeetingNote`, `NotesMarkdown`) |
| Auto-stop observable state + `keepRecording()` + deep-link routing | `AppCore` |
| Header button + sidebar row | `AppShellUI` (`AppShellView`, `AppShellViewModel`) |
| Tab lift + pending jump | `MeetingDetailUI` (`MeetingDetailView`/`ViewModel`) |
| URL scheme + `onOpenURL` | App target (`Info.plist`, `BiscottiApp`, `AppDelegate`) |
| New color tokens + light button style | `DesignSystem` |

No SwiftData schema change. No third-party dependency fork (the deep link uses a
registered URL scheme, §10).

---

## 1. Shared editable-title control (`EditableMeetingTitle`)

Extract the inline title control currently inlined in `MeetingDetailView.header`
(the `ZStack` of `TextField` + truncating `Text`, the focus box, the `selectAll`
on tap, and the click-away `NSEvent` local monitor) into a reusable `View` in
`DesignSystem`.

```swift
public struct EditableMeetingTitle: View {
    @Binding var text: String          // two-way to the editable buffer
    var placeholder: String            // "Untitled meeting" / "Untitled recording"
    var font: Font                     // .biscottiSerif(27) / .biscottiSerif(26)
    var tracking: CGFloat = -0.27
    var onCommit: () async -> Void     // persist (Return / click-away)

    public init(text: Binding<String>, placeholder: String, font: Font,
                tracking: CGFloat = -0.27, onCommit: @escaping () async -> Void)
}
```

- Owns its `@FocusState`, `titleFrame`, and `clickAwayMonitor` state and the
  install/remove lifecycle (moved verbatim from `MeetingDetailView`).
- Behavior must be byte-for-byte the current meeting-detail behavior: tap → focus
  + `selectAll`; tail truncation when unfocused; white-fill + sage 2pt focus box
  bleeding outward; Return/click-away → `onCommit`.
- **Callers:**
  - `MeetingDetailView`: `EditableMeetingTitle(text: $viewModel.editableTitle,
    placeholder: "Untitled meeting", font: .biscottiSerif(27)) { await viewModel.saveTitle() }`.
    Removes the inlined control + its private monitor helpers.
  - `RecordingView`: `placeholder: "Untitled recording", font: .biscottiSerif(26)`,
    `onCommit: { await viewModel.saveTitle() }`.
- Testing: none (AppKit/SwiftUI view) — verified via the existing meeting-detail
  manual flow + the new recording flow.

---

## 2. In-memory during-meeting notes (`RecordingController`)

A new value type in the `Recording` module:

```swift
public struct MeetingNote: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var text: String
    public let timestamp: TimeInterval   // recording elapsed when added
}
```

`RecordingController` gains observable, **insertion-order (oldest-first)** state
and mutators:

```swift
public private(set) var notes: [MeetingNote] = []

public func addNote(text: String)                 // stamps state.elapsed, appends
public func updateNote(id: UUID, text: String)    // content only; timestamp kept
public func removeNote(id: UUID)
```

- `addNote` ignores empty/whitespace-only text. Timestamp = `state.elapsed`.
- `start()` resets `notes = []` (alongside the existing session reset).
- The view presents **newest-first** by reversing; storage stays oldest-first
  (matches the markdown order, §3).

### 2.1 Seeding on stop

In `RecordingController.stop()`, after audio-presence/duration persistence and
**before** `state`/`notes` are reset, generate markdown and write it:

```swift
if let md = NotesMarkdown.generate(notes: notes, meetingID: meetingID) {
    let existing = (try? await store.meetingDetail(id: meetingID))?.notes ?? ""
    try? await store.setNotes(NotesMarkdown.merged(existing: existing, section: md),
                              for: meetingID)
}
notes = []
```

This covers **both** manual Stop & Save and auto-stop (both route through
`AppCore.stopRecording()` → `recording.stop()`). Failures are logged, non-fatal
(existing pattern). Uncommitted composer text is committed by the VM only on
manual stop (§4.6); on auto-stop, uncommitted composer text is intentionally
dropped.

---

## 3. Markdown generation (`NotesMarkdown`, pure)

```swift
public enum NotesMarkdown {
    /// Returns the "### Notes During Meeting" section, or nil if no notes.
    public static func generate(notes: [MeetingNote], meetingID: UUID) -> String?
    /// Combine with any existing notes (append after a blank line if non-empty).
    public static func merged(existing: String, section: String) -> String
    static func timeLabel(_ seconds: TimeInterval) -> String  // m:ss / h:mm:ss
}
```

Output (oldest-first):

```
### Notes During Meeting

[0:42](biscotti://meeting/{id}?time=42.0)
Whatever they typed at 42s

[1:42](biscotti://meeting/{id}?time=102.2)
Whatever they typed at 1m42s
```

- Link: `[{timeLabel}](biscotti://meeting/{id}?time={seconds})`; `{seconds}` is the
  raw elapsed with one decimal.
- `merged`: `existing.isEmpty ? section : existing + "\n\n" + section`.
- Pure + fully unit-tested (§12).

---

## 4. `RecordingViewModel`

Currently a thin projection. It grows to own the pane's data. It keeps reading
from `AppCore`; new dependencies are `core.store`, `core.autoStop`, and the
in-progress meeting's detail.

### 4.1 Meeting load

```swift
private var detail: MeetingDetailData?
func load() async   // core.store.meetingDetail(id: meetingID)
```

- Run on `.task(id: meetingID)` and reload when `core.summaries` changes (so the
  calendar context attached shortly after `start()` is picked up). To make
  association observable, `AppCore.startRecording` calls `reloadSummaries()` after
  `associateEvent` (cheap; also fixes sidebar/home title staleness during
  recording).

### 4.2 Title (uses §1)

- `editableTitle: String` binds directly to `detail?.title` (rendered like the
  meeting-detail title — the default "Untitled Meeting" shows as ordinary text;
  no special-casing of the auto-title).
- `saveTitle()`: mirrors `MeetingDetailViewModel.saveTitle` — trim; skip if
  unchanged; revert to stored title if blanked; else `store.setTitle` + refresh
  `detail` + `reloadSummaries()` (keeps sidebar/header live).

### 4.3 Submeta + calendar

From `detail?.calendar`:
- `hasEvent`, `scheduleText` (`start – end`, locale time), `platformText`
  (`conferencePlatform`, optional), `openInCalendar()` via `CalendarDeepLink`
  (eventIdentifier + startDate), `startedClockText` (meeting date) for ad-hoc.

### 4.4 Time chips

```swift
enum LeftChip: Equatable { case none, normal(String), warning(String), overtime(String) }
static func leftChip(scheduledEnd: Date?, now: Date) -> LeftChip
```

- `none` when `scheduledEnd == nil`. Else `remaining = end - now`:
  `remaining > 300` → `.normal`; `0 < remaining ≤ 300` → `.warning`; `≤ 0` →
  `.overtime("+m:ss")`.
- The view re-renders each second because `core.recording.state.elapsed` ticks;
  the chip reads `Date()` at render. Pure `leftChip` is unit-tested.
- `elapsedText` unchanged.

### 4.5 Notes proxy

```swift
var notes: [MeetingNote] { core.recording.notes.reversed() }   // newest-first
func addNote(_ text: String) { core.recording.addNote(text: text) }
func updateNote(id: UUID, text: String)
func removeNote(id: UUID)
```

Composer text + per-row edit text are view `@State`. On submit/commit the view
calls the proxy.

### 4.6 Stop + auto-stop

```swift
func stop(pendingComposer: String) async {   // commit then stop
    let t = pendingComposer.trimmingCharacters(in: .whitespacesAndNewlines)
    if !t.isEmpty { core.recording.addNote(text: t) }
    await core.stopRecording()
}

var autoStopCountdown: AutoStopState? {        // only for THIS recording
    guard let a = core.autoStop, a.meetingID == core.recording.state.meetingID else { return nil }
    return a
}
func keepRecording() { core.keepRecording() }
```

`showSystemAudioWarning` / `systemAudioSettingsURL` unchanged.

---

## 5. Auto-stop observable state (`AppCore`, additive)

The merged countdown uses a single `sleep(autoStopSeconds)` + one static
notification. We add an observable deadline the pane renders against — **no
change to the existing notification/sleep logic**.

```swift
public struct AutoStopState: Sendable, Equatable {
    public let meetingID: UUID
    public let deadline: Date        // Date() + autoStopSeconds at begin
    public let total: TimeInterval   // autoStopSeconds
}

public private(set) var autoStop: AutoStopState?
public func keepRecording() {
    if case let .recording(id) = runState { cancelAutoStopCountdown(meetingID: id) }
}
```

- `beginAutoStopCountdown`: set `autoStop = AutoStopState(meetingID, Date()+seconds, seconds)`.
- `cancelAutoStopCountdown`: set `autoStop = nil`.
- `stopRecording` already cancels the countdown (→ `autoStop = nil`); the
  auto-fire path calls `stopRecording`, which clears it too.
- Trigger is unchanged: `.allMicUsersStopped` → `handleAllMicUsersStopped` (any
  in-progress recording).

---

## 6. On-screen countdown bar (`RecordingView`)

Rendered only when `viewModel.autoStopCountdown != nil`, pinned at the top of the
column. Driven by the deadline (no per-second AppCore state needed):

```swift
TimelineView(.animation) { ctx in
    let remaining = max(0, a.deadline.timeIntervalSince(ctx.date))
    // bar fraction = remaining / a.total ; label = Int(ceil(remaining))
}
```

- Reduce Motion (`@Environment(\.accessibilityReduceMotion)`): use
  `TimelineView(.periodic(from: .now, by: 1))` so the bar steps each second
  without a smooth tween.
- "Keep Recording" → `viewModel.keepRecording()`.

---

## 7. Header record button (`AppShellUI` + `DesignSystem`)

- New reusable **light alert** button style in `DesignSystem`, shared with Stop &
  Save: white `cardFill`, `recordingOutline` 0.5pt border, whisper shadow,
  `signalRed` content, `recordingHoverFill` on hover.

  ```swift
  public struct LightAlertButtonStyle: ButtonStyle { /* chrome only; size via label padding */ }
  ```

- `AppShellView` recording branch: `LightAlertButtonStyle`, a leading 8pt
  `signalRed` dot with a slow pulse (view-level animation, gated on
  `accessibilityReduceMotion`), label `"REC \(viewModel.recordingElapsedText)"`
  in `.monoMetaMedium` `signalRed`, with larger horizontal padding/height than
  idle. Idle branch unchanged (`ToolbarRecordButtonStyle(fill: .sage)`).

---

## 8. Sidebar "RECORDING NOW" (`AppShellUI`)

- `AppShellViewModel`: add `recordingMeetingTitle: String` (=
  `summaries.first { $0.id == recordingMeetingID }?.title` with a sensible
  fallback); reuse `isRecording` and `showRecording()`. Title stays live because
  `RecordingViewModel.saveTitle()` calls `reloadSummaries()`.
- `AppShellView`: a new `RecordingNowSection` placed after the brand lockup and
  before `homeRow`, shown when `viewModel.isRecording`:
  - kicker `"RECORDING NOW"` (`signalRed`),
  - one two-line row (title + "Recording" subtitle in `signalRed`),
  - background `recordingTintSoft`; when `route == .recording`,
    `recordingTintStrong` + inset `recordingOutlineStrong` stroke,
  - tap → `viewModel.showRecording()`.

---

## 9. Meeting-detail tab lift + pending jump (`MeetingDetailUI`)

To let the deep-link handler drive the open meeting:

- Move `Tab` to `MeetingDetailViewModel` and add `var selectedTab: Tab =
  .transcript`. `MeetingDetailView`'s `Picker` binds to `$viewModel.selectedTab`
  (replaces the local `@State`).
- The VM reacts to `core.pendingTranscriptJump` (see §10):

  ```swift
  func applyPendingJumpIfNeeded() async {
      guard let j = core.pendingTranscriptJump, j.meetingID == meetingID else { return }
      selectedTab = .transcript
      pendingSeek = j.time                 // applied now if audio ready, else after load
      applySeekIfReady()                   // seek(to: min(time, duration))
      core.consumeTranscriptJump()
  }
  ```

  The view calls this via `.onChange(of: core.pendingTranscriptJump)` (and once on
  appear). If the audio player isn't loaded yet, `pendingSeek` is retained and
  applied at the end of `loadAudioPlayer()`. `seek(to:)` already exists; clamp to
  duration.

---

## 10. Deep link: URL scheme + handler

The notes markdown link is `biscotti://meeting/{id}?time={seconds}`. In the
`MarkdownEditor` (third-party `NSTextView`) a click on this link escapes via
`NSWorkspace.open`; macOS routes it back to the running app.

- **Registration:** add `CFBundleURLTypes` → `CFBundleURLSchemes = ["biscotti"]`
  to `App/Resources/Info.plist` (the project uses an explicit Info.plist;
  `GENERATE_INFOPLIST_FILE = NO`).
- **Entry point:** `BiscottiApp`'s `WindowRootView` gains
  `.onOpenURL { url in appDelegate.handleOpenURL(url) }`. `AppDelegate.handleOpenURL`
  calls `showMainWindow()` then `core?.handleDeepLink(url)`.
- **AppCore:**

  ```swift
  public struct TranscriptJump: Sendable, Equatable { public let meetingID: UUID; public let time: TimeInterval }
  public private(set) var pendingTranscriptJump: TranscriptJump?
  public func consumeTranscriptJump() { pendingTranscriptJump = nil }

  public func handleDeepLink(_ url: URL) {
      // scheme == "biscotti", host == "meeting", path = "/{uuid}", query time
      // validate UUID + meeting exists; else no-op
      select(id)                                  // route .meetings + selection
      pendingTranscriptJump = TranscriptJump(meetingID: id, time: seconds)
  }
  ```

- Only `host == "meeting"` is handled. The in-SwiftUI transcript links
  (`biscotti://seek?t=…`) are intercepted by `OpenURLAction` in
  `SelectableTranscriptView` and never reach `onOpenURL`; registering the scheme
  is additive and doesn't change them.
- Missing/invalid id (e.g. deleted meeting) → no-op.

---

## 11. New `DesignSystem` tokens

Add the §2 tokens from `ui_design.md` (`recordingTintSoft/Strong`,
`recordingOutline/Strong`, `recordingHoverFill`, `warningChipFill`,
`warningChipText`, `softSageFill`) as `Color` extensions + `Tokens` aliases,
derived from `signalRed` / `warningOchre` / `sage`. Reuse existing
`warningBackground` / `accentWash*` where they already match to avoid duplicates.

---

## 12. Testing strategy

Unit tests (`swift test`, gating) — logic only; SwiftUI/AppKit views are
verified manually/in previews.

- **`NotesMarkdown`**: `generate` format + oldest-first order; empty → nil; one
  decimal seconds; `timeLabel` (m:ss / h:mm:ss); `merged` empty vs non-existing.
- **`RecordingController` notes**: `addNote` stamps `elapsed` + ignores blank;
  `updateNote` changes text but keeps timestamp; `removeNote`; `start()` clears;
  `stop()` seeds via an in-memory `DataStore` and clears (assert the meeting's
  `notes` contains the section).
- **`RecordingViewModel`**: `leftChip` (none/normal/warning/overtime + label);
  submeta builders; `autoStopCountdown` derivation (matches only the active
  meeting); `stop(pendingComposer:)` commits non-empty.
- **`AppCore`**: `autoStop` set on `.allMicUsersStopped` while recording, cleared
  on `keepRecording()` / `stopRecording()` / auto-fire; `handleDeepLink` parsing
  (valid → selection + `pendingTranscriptJump`; bad scheme/host/uuid → no-op);
  `consumeTranscriptJump` clears.
- **`MeetingDetailViewModel`**: pending jump for this meeting sets
  `selectedTab == .transcript` + seeks (clamped); a jump arriving before audio
  loads is applied after `loadAudioPlayer`.

**Existing tests to update:** any auto-stop tests now also assert the new
`autoStop` state; `MeetingDetailView` tab is bound to the VM (update if a test
referenced the local state).

**Manual-test staleness:** this project touches `RecordingUI`, `Recording`,
`AppShellUI`, `MeetingDetailUI`, `DesignSystem`, and the App target — **not**
`Packages/Transcription` or `Packages/AudioCapture` — so the `ManualTestApp`
staleness rule does not apply (no `ac_*` / `tx_*` results to mark not-run).

---

## 13. Non-goals / explicit decisions

- No SwiftData schema change (notes seed the existing `Meeting.notes` String).
- No transcript restructuring; `meeting_time` jump = switch tab + seek only.
- No markdown-engine fork (URL scheme instead).
- No reintroduced per-second AppCore countdown (deadline + `TimelineView`).
- Idle header button unchanged; only the recording-state styling changes.
