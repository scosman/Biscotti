---
status: complete
---

# Architecture: Update Meeting Screen

Technical design for the `MeetingDetailView` redesign. This is a **single-doc**
architecture (no separate component files): the new technical surface is small
and lives almost entirely inside the existing `MeetingDetailUI` +
`DesignSystem` modules, with one tiny `DataStore` read-model addition.

Read `functional_spec.md` for behavior and `ui_design.md` for the visual
contract. This doc fixes the component decomposition, public signatures, the
hard bits (selectable transcript + seek links, pinned-chrome scroll model,
playback rate), and the test plan — so the coding agent executes, not designs.

---

## Module map

| Module | Role | Changes |
|---|---|---|
| `MeetingDetailUI` | the screen + view model | `MeetingDetailView` rewrite; `MeetingDetailViewModel` gains rate, reveal-in-Finder, transcript copy, calendar-card mapping; new `TranscriptContent` builder + `SeekLink` helper. |
| `DesignSystem` | shared views/tokens | new `SourcePill`, `CalendarInfoCard`, `SelectableTranscriptView`; `AudioTransport` restyle + speed menu. Reuse `Avatar*`, `Font.*`, `Tokens`. |
| `MeetingDetailUI/AudioPlaybackProviding` | playback seam | add `rate`. |
| `DataStore` | read models | add `eventNotes` to `CalendarContextData` + populate from `CalendarSnapshot`. |
| `MarkdownEditorUI` | notes editor | **no change** (used at fill height). |

State stays in the existing `@MainActor @Observable MeetingDetailViewModel`
(cached per meeting in `AppShellViewModel`). View-local `@State`: the selected
`Tab` (in the view) and the calendar `DisclosureGroup` expansion (inside
`CalendarInfoCard`). The detail view is `.id(meetingID)`, so both reset per
meeting — intended.

---

## View structure — single scroll, fill-with-500-floor

The whole column lives in **one** outer `ScrollView` (so content is always
reachable when squeezed). We measure the chrome height and size the Notes editor
to fill the remaining height **with a hard 500pt floor**. That makes the chrome
*appear pinned* whenever there's room (the editor exactly fills, so the outer
scroller has nothing to do) and lets the pane scroll only when there isn't —
**no common-case double scroll.**

```swift
private static let minNotesHeight: CGFloat = 500
@State private var chromeHeight: CGFloat = 0    // measured

GeometryReader { geo in
  ScrollView {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: Tokens.spacingMD) {        // chrome
        header                              // serif title + "…" menu + meta line
        if let card = vm.calendarCard { CalendarInfoCard(data: card,
                                            onOpenInCalendar: vm.openInCalendar) }
        AudioTransport(... rate binding ...)                          // restyled card
        tabBar                              // segmented Picker + version picker + Copy
      }
      .background(GeometryReader { c in Color.clear
        .preference(key: ChromeHeightKey.self, value: c.size.height) })

      Divider().padding(.vertical, Tokens.spacingMD)

      let fill = max(Self.minNotesHeight, geo.size.height - chromeHeight)
      switch tab {
      case .notes:
        MarkdownEditor(...).frame(height: fill)              // exact fill / 500 floor
      case .transcript:
        transcriptContent.frame(minHeight: fill, alignment: .topLeading) // grows past; no max
      }
    }
    .padding(.horizontal, 32).padding(.top, 24)
    .frame(maxWidth: 760, alignment: .leading)
  }
  .onPreferenceChange(ChromeHeightKey.self) { chromeHeight = $0 }
}
.background(Tokens.contentBackground)
// existing: .task load, .onChange jobStatus, .onDisappear flush,
//           .sheet(EventPickerSheet), .confirmationDialog(delete)
```

Behavior:
- **Notes, room available** (`geo.h − chrome ≥ 500`): editor height = remaining,
  so total content ≈ viewport → outer scroller idle → **chrome looks pinned**;
  long notes scroll **inside** the editor only. Single scroll.
- **Notes, squeezed** (`< 500` left — small window or a tall expanded calendar
  card): editor stays at the 500 floor → total > viewport → the outer `ScrollView`
  scrolls to reveal it (chrome scrolls away to guarantee the floor). Editing area
  is never smaller than 500.
- **Transcript:** the selectable `Text` uses `minHeight: fill` (no max) → grows
  with content; the **outer** `ScrollView` scrolls it (chrome scrolls away while
  reading). No inner `ScrollView` ⇒ no double scroll. Processing / failed / empty
  states render in this same branch.

`ChromeHeightKey` is a trivial `PreferenceKey` (max of reported heights).
`chromeHeight` is independent of the content height (chrome = title / calendar /
transport / tabs), so there is **no layout feedback loop**. The Notes editor gets
a **definite** height (not `maxHeight: .infinity`), avoiding the greedy-NSScrollView-
in-ScrollView infinite-height trap. 760pt reading cap on the inner column; ivory
fills the rest of the pane.

> **Superseded 2026-08:** the `GeometryReader` → `PreferenceKey` →
> `.onPreferenceChange` measurement described here caused
> "AttributeGraph: cycle detected" warnings at runtime (the geometry → state →
> layout round-trip *is* a feedback loop, contrary to the claim above).
> `MeetingDetailView` now measures chrome/transport heights with
> `onGeometryChange(for:action:)`, which writes `@State` directly with no
> preference propagation. The height-consumption design below is unchanged.

---

## Playback rate (P2)

### Seam — `AudioPlaybackProviding`
```swift
public protocol AudioPlaybackProviding: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }
    var rate: Float { get set }          // NEW. Default 1.0. Applies to all tracks.
    func play(); func pause()
    func load(urls: [URL]) throws
}
```

### `AVAudioPlayerWrapper`
- Store `private var currentRate: Float = 1.0`.
- In `load(urls:)`, for each player: set `player.enableRate = true` **before**
  `prepareToPlay()`, then apply `player.rate = currentRate` (re-apply on reload).
- `var rate: Float { get { players.first?.rate ?? currentRate }
   set { currentRate = newValue; players.forEach { $0.rate = newValue } } }`
- Setting `rate` while playing applies immediately and does **not** change
  `isPlaying`; while paused it persists to the next `play()`. Both tracks get the
  same rate (started sample-aligned via `play(atTime:)`; rate scales both).

### View model
```swift
public private(set) var playbackRate: Float = 1.0       // @Observable
public func setPlaybackRate(_ r: Float) { playbackRate = r; audioPlayer?.rate = r }
static let speedOptions: [Float] = [0.5, 1.0, 1.25, 1.5, 2.0]
```
Default 1.0 on load. The transport's speed `Menu` reads `playbackRate` and calls
`setPlaybackRate`. Label format: `"1×"`, `"1.25×"` (trim trailing `.0`).

### `AudioTransport` (DesignSystem)
Add inputs `rate: Float`, `speedOptions: [Float]`, `onRate: (Float) -> Void`, and
render the soft-secondary speed `Menu` (disabled when `isDisabled`). Restyle the
bar into a card (play/pause circle with hover fill, sage slider, mono tabular
times). Keep `formatTime` (reused by the transcript).

---

## Transcript — selectable block + seek links + copy

A single selectable `Text(AttributedString)`. Builders are **pure + unit-tested**.

### `TranscriptContent` (MeetingDetailUI)
```swift
enum TranscriptContent {
    /// One AttributedString for the whole transcript. Per turn:
    ///   <speaker semibold, speakerColor>  <timestamp mono inkTertiary [+ seek link]>
    ///   \n <text system 14, inkSecondary> \n\n
    static func attributedString(_ segments: [SegmentData], canSeek: Bool) -> AttributedString

    /// Plain text for the pasteboard: "<speaker>  MM:SS\n<text>\n\n".
    static func plainText(_ segments: [SegmentData]) -> String

    /// Stable per-speaker color from the shared palette.
    static func speakerColor(for label: String) -> Color {
        Tokens.avatarPalette[avatarColorIndex(forKey: label,
                              paletteCount: Tokens.avatarPalette.count)]
    }
}
```
- Timestamp text uses `AudioTransport.formatTime(seg.startTime)`,
  `Font.biscottiMono(12)`. When `canSeek`, set the run's `.link =
  URL("biscotti://seek?t=\(seg.startTime)")`; otherwise no link.
- Use SwiftUI attribute scopes (`.font`, `.foregroundColor`, `.link`).

### `SelectableTranscriptView` (DesignSystem or MeetingDetailUI)
```swift
Text(attributed)
    .textSelection(.enabled)
    .tint(.inkTertiary)                    // seek links render subtle, not accent-blue
    .environment(\.openURL, OpenURLAction { url in
        if let t = SeekLink.seconds(from: url) { onSeek(t); return .handled }
        return .systemAction               // pass non-seek URLs through
    })
```
- `.textSelection(.enabled)` gives continuous drag-selection across turns; ⌘C
  copies the selection. Tapping a timestamp fires the link (drag still selects).
- `SeekLink.seconds(from:)` is a **pure, tested** parser:
  `url.scheme == "biscotti" && url.host == "seek"` → `t` query → `Double`.
- `onSeek(t)` → `viewModel.seek(to: t)` (sets `currentTime` only ⇒ **preserves
  play/pause state**, verified).

### Copy
`MeetingDetailViewModel.copyTranscript()` builds `TranscriptContent.plainText(...)`
and writes it to `NSPasteboard.general` (`clearContents()` + `setString(_, .string)`).
The "Copy Transcript" button (Transcript tab only, when a transcript is ready)
calls it.

### Performance note
Single non-virtualized `Text` — fine for typical meetings; very long transcripts
render as one block (accepted; NSTextView fallback is out of scope).

---

## Calendar info card

### Data model addition (`DataStore`)
`CalendarContextData` gains `public let eventNotes: String?` (+ init param).
Populate it wherever `CalendarContextData` is built from a `CalendarSnapshot`
(the meeting-detail read query in `DataStore`) by passing `snapshot.eventNotes`.
This is the **only** DataStore change.

### `CalendarInfoCard` (DesignSystem)
Value-typed; no view model. The view maps `CalendarContextData` → a display
struct (DesignSystem must not depend on DataStore):
```swift
public struct CalendarCardData {
    public var attendees: [AvatarPerson]   // for the avatar cluster
    public var attendeeTotal: Int
    public var summary: AttributedString   // organizer name .medium + others .inkSecondary
    public var whenText: String?           // "Yesterday, Jun 11 · 4:18 – 4:50 PM"
    public var platform: String?
    public var conferenceURL: URL?
    public var location: String?
    public var eventNotes: String?
    public var invitedText: String?        // "Steve (organizer) · Alex · Jay · +2"
}

public struct CalendarInfoCard: View {
    let data: CalendarCardData
    let onOpenInCalendar: () -> Void
    @State private var expanded = false
    // Row A: AvatarCluster + summary + Spacer + "Open in Calendar" (soft secondary)
    // Divider
    // Row B: DisclosureGroup("Description", isExpanded: $expanded)
    //   collapsed: + one truncated line of eventNotes
    //   expanded: Grid definition list — WHEN / WHERE / DESCRIPTION / INVITED
}
```
- Card: `RoundedRectangle(cornerRadius: 12)` `Tokens.cardFill`, 0.5pt
  `Color.cardStroke`, inner padding `spacingMD`.
- Avatars: reuse `AvatarCluster(people:totalCount:size: 26)`.
- "(Re)association" is **not** here — it lives in the "…" menu.
- The card is shown only when `vm.calendarCard != nil` (event linked).

### Display-string mapping (view model, testable)
The VM exposes `var calendarCard: CalendarCardData?` computed from
`calendarContext`, plus pure helpers for `whenText` (date-range formatter) and
`invitedText` (organizer + attendees + "+N"). Unit-test these.

---

## "…" overflow menu — action wiring

All but one map to **existing** VM methods:

| Item | Visible when | Action |
|---|---|---|
| Reveal in Finder | audio files present | `vm.revealInFinder()` **(new)** |
| Re-transcribe | `vm.canReTranscribe` | `vm.reTranscribe()` (existing) |
| Link Calendar Event… | no event linked | `vm.presentAssociationCorrection()` (existing) |
| Change Calendar Event… | event linked | `vm.presentAssociationCorrection()` (existing) |
| Unlink Calendar Event | event linked | `vm.removeAssociation()` (existing) |
| Delete Meeting… (`.destructive`) | always | `vm.requestDelete()` (existing) → confirmationDialog |

### `revealInFinder()` (new)
```swift
public func revealInFinder() {
    let refs = core.store.audioFileRefs(meetingID: meetingID)   // already used for playback
    let urls = [refs.mic, refs.system].compactMap { $0 }
    guard !urls.isEmpty else { return }
    NSWorkspace.shared.activateFileViewerSelecting(urls)
}
```
Expose `var hasAudioFiles: Bool` so the menu can hide/disable the item.

The standalone delete section is **removed** (delete now lives in the menu).

---

## `SourcePill` (DesignSystem)
```swift
public struct SourcePill: View {       // shown only when a platform is known
    let platform: String
    // HStack(spacing: 4): Image("video.fill").foregroundStyle(.sage)
    //                     Text(platform).foregroundStyle(.inkSecondary)
    //  .font(.system(size: 11, weight: .medium))
    //  .padding(.horizontal, 7).frame(height: 19)
    //  .background(Tokens.neutralChip, in: Capsule())
}
```

---

## Header & tab bar

- **Header:** inline-editable `TextField($vm.editableTitle)` `.plain`,
  `Font.biscottiSerif(27)`, `tracking(-0.27)` (reuse existing save-on-submit /
  save-on-disappear). Trailing borderless `Menu` (`ellipsis.circle`). Meta line:
  `Text(vm.formattedDate).font(.monoMeta)` · duration · `SourcePill` (when
  platform known).
- **Tab bar:** `HStack { Picker(.segmented).fixedSize(); Spacer();
  if tab == .transcript { VersionPicker (when versions>1); CopyButton } }`.
  `Picker` bound to local `@State tab` (default `.transcript`).

---

## Error handling

- **Reveal in Finder, no files:** guard empty → no-op; the menu item is
  hidden/disabled via `hasAudioFiles`.
- **Malformed seek URL:** `SeekLink.seconds` returns `nil` → handler returns
  `.systemAction` (no seek, no crash).
- **No audio (`!canPlay`):** transport disabled; speed menu disabled; transcript
  built with `canSeek: false` (timestamps are plain, non-link text).
- **No calendar event:** `calendarCard == nil` → card omitted; menu shows only
  "Link Calendar Event…".
- **Rate:** restricted to `speedOptions`; no failure mode.
- All existing error paths (load failure banner, delete guards, autosave) are
  unchanged.

---

## Testing strategy

`swift test` (BiscottiKit), view-model + pure-helper level. No UI snapshot tests.

| Unit test | Asserts |
|---|---|
| `TranscriptContent.plainText` | exact "<speaker>  MM:SS\n<text>\n\n" format, multi-turn, H:MM:SS for ≥1h. |
| `TranscriptContent.attributedString` | per-turn runs present; `canSeek:true` adds `.link` with correct `t`; `canSeek:false` adds none. |
| `SeekLink.seconds(from:)` | valid `biscotti://seek?t=14.0` → 14.0; wrong scheme/host/missing `t` → nil. |
| `TranscriptContent.speakerColor` | same label → same palette color; different labels differ (modulo palette size). |
| VM `setPlaybackRate` | updates `playbackRate` and calls through to the seam (assert on a fake player). |
| VM `calendarCard` / `whenText` / `invitedText` | correct strings incl. organizer tag + "+N" overflow; nil when no context. |
| VM `revealInFinder` (light) | builds URL list from refs; no-op on empty (inject a fake store). |

- The existing test fake for `AudioPlaybackProviding` gains a `rate` stored
  property.
- `AVAudioPlayerWrapper.rate` and two-track audio sync are **manual/hardware**
  (no unit coverage for real audio) — but **not** in `ManualTestApp`'s gated
  scripts (this touches `MeetingDetailUI`, not `Packages/AudioCapture` /
  `Packages/Transcription`), so the manual-test staleness gate is unaffected.

---

## Non-goals / out of scope
Export transcript; Summary/Action-Items tabs; custom vocab; the gated
re-transcribe-after-correction prompt; real per-speaker identities; any
app-shell/sidebar/list change; virtualized transcript rendering.

## Risks
1. Single-`Text` transcript perf on multi-hour transcripts (accepted).
2. Two-track rate sync drift — verify on hardware (minor).
3. Short windows / tall calendar card — handled by the 500pt Notes floor + outer
   scroll (chrome scrolls away only when it must). Verify the chrome-height
   measurement settles without jitter during Phase 4.
4. SwiftUI link styling inside selectable `Text` — mitigated with `.tint(.inkTertiary)`;
   verify drag-select + tap-to-seek coexist on macOS 15 during Phase 2.
