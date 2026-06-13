---
status: complete
---

# Architecture: redesign_2 — Design Project 1 (App Container + Home)

A UI-polish project. No new frameworks, no new processes, no schema changes.
The work is: (1) add a shared palette + a small set of reusable views to
`DesignSystem`, (2) a read-only extension to one read-model in `DataStore`,
(3) new derivations + actions on `HomeViewModel`, and (4) a rebuilt `HomeView`.

**Single-doc decision:** this is small/medium and self-contained — one
`architecture.md`, no per-component sub-docs.

**Single clock:** all time-derived state (greeting, date line, countdowns, the
hero join-window) reads `core.minuteTick` (already updated each wall-clock
minute and already used by Home's `tickTimeText`). Tests drive it via the
existing `core.setMinuteTick(_:)` helper. Minute granularity is sufficient for
a ±15-min window. No separate injected clock is added to Home.

---

## 1. Module map — what changes and where

| Module | Change | Kind |
|---|---|---|
| `DesignSystem` | New palette/type tokens; new `Avatar`/`AvatarCluster`, `StatChip`, `MeetingPlatformChip`, `homeCard()` modifier + inset divider, `JoinRecordButtonStyle`; pure helpers `avatarInitials`/`avatarColorIndex` | additive |
| `DataStore` | Extend `MeetingSummary` with `participants` + `participantCount`; map them in `meetingSummaries(...)` | additive, read-only |
| `AppCore` | Add shared `MeetingTiming.joinWindowSeconds` constant | additive |
| `HomeUI` | Extend `HomeViewModel` (greeting/date/stat-chips/hero/avatars/actions); rebuild `HomeView`; apply `#FBFBFC` background | rewrite of Home |
| `AppShellUI` | Inject `urlOpener` when constructing `HomeViewModel` (one line) | 1-line |

**No new cross-module edges.** `HomeUI` already imports `AppCore`, `Calendar`,
`DataStore`, `DesignSystem`. It does **not** import `MeetingDetailUI`; the hero
reuses domain actions through `AppCore`, not `EventPreviewViewModel`.
`DesignSystem` stays dependency-free — its views take primitive inputs, and
`HomeUI` does the `CalendarEvent`/`MeetingSummary` → `AvatarPerson` mapping.

Untouched: sidebar, toolbar (search + Record), all other screens.

---

## 2. DesignSystem additions

### 2.1 Tokens (palette + type/radii)
Extend `enum Tokens` (`DesignSystem/Tokens.swift`). New values, all from
`agent_spec.md` §1/§6:

```
// Surfaces
static let contentBackground = Color(red: 0.984, green: 0.984, blue: 0.988) // #FBFBFC
static let cardFill          = Color.white
// Lines & fills
static let hairline   = Color.black.opacity(0.08)
static let cardStroke = Color.black.opacity(0.07)
static let neutralChip = Color.black.opacity(0.05)
// Accent washes (systemBlue stays stock via Color.accentColor)
static let accentWashSoft  = Color.accentColor.opacity(0.06) // hero row
static let accentWashStrong = Color.accentColor.opacity(0.14) // (selection — unused here)
// Status
static let liveGreen = Color(red: 0.102, green: 0.616, blue: 0.353) // #1A9D5A
// Avatars: fixed 16-color palette (stable order; never reordered)
static let avatarPalette: [Color] = [ /* 16 distinct hues */ ]
```

Type/spacing constants Home needs (greeting 32 bold tracking -0.6; soon title
16 semibold; row title 14.5 medium; meta 12.5; group label 11.5 semibold
uppercase; radii 12/8/7/6) are added as needed; reuse existing `Tokens.*`
where a match already exists. Existing tokens are not renamed.

### 2.2 Avatar system (pure helpers + views)
DesignSystem owns the algorithm so it is unit-testable without app data.

```
public struct AvatarPerson: Hashable, Sendable {
    public let displayName: String
    public let email: String?
    public init(displayName: String, email: String?)
}

// Two-letter initials: first(firstToken)+first(lastToken), uppercased.
// One token -> first two letters. Empty -> "" (caller renders a glyph).
public func avatarInitials(for name: String) -> String

// Deterministic, stable ACROSS LAUNCHES (FNV-1a over lowercased/trimmed key;
// NOT Swift's randomized Hasher). Key = email if non-empty else displayName.
// Returns 0..<palette count.
public func avatarColorIndex(forKey key: String, paletteCount: Int = 16) -> Int
```

`avatarColorIndex` reference impl (FNV-1a 32-bit):
```
var h: UInt32 = 2166136261
for b in key.lowercased().trimmed.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
return Int(h % UInt32(paletteCount))
```

Views:
```
public struct Avatar: View            // circle: gradient(palette[idx]→darker),
  // init(person:, size: CGFloat = 26, stacked: Bool = false)
  // white .semibold initials; inset hairline ring; +2pt white ring when stacked.
  // Empty initials -> person.fill glyph in white.

public struct AvatarCluster: View     // the fixed 78pt column
  // init(people: [AvatarPerson], totalCount: Int, size: CGFloat = 26,
  //      columnWidth: CGFloat = 78)
  // Renders up to 3 overlapped avatars (HStack spacing = -0.66*size, stacked:true),
  // then a neutral "+N" badge where N = max(0, totalCount - shown).
  // Pinned to .frame(width: columnWidth, alignment: .leading).
```

### 2.3 Other reusable views

```
public struct StatChip: View
  // init(icon: String, tint: Color, text: String)
  // HStack(spacing:5){ Image(systemName:icon).foregroundStyle(tint); Text(text) }
  // height 24, padding 0/10, RoundedRectangle(7).fill(Tokens.neutralChip),
  // text 12.5 .medium .secondary.

public struct MeetingPlatformChip: View      // the "Meet chip"
  // init(platform: String)  // e.g. "Google Meet"
  // capsule: video.fill (Tokens.liveGreen) + label 11 .medium .secondary,
  // height 19, padding 0/7, radius 6, fill black@6%.

public struct JoinRecordButtonStyle: ButtonStyle
  // accent fill, white 13.5 .semibold, height 32, radius 8, subtle top highlight,
  // pressed = dim. Used by the hero "Join & Record"/"Record" button.

public extension View {
  func homeCard() -> some View
  // background(Tokens.cardFill), cornerRadius 12, clip,
  // overlay(RoundedRectangle(12).stroke(Tokens.cardStroke, lineWidth: 0.5)),
  // shadow(color: black@5%, radius: 1.5, y: 1).
}

public struct InsetDivider: View   // 0.5pt Tokens.hairline, leadingInset 14
```

Rows are composed manually in a `VStack(spacing: 0)` with `InsetDivider`
between rows (first row no divider) — **not** a `List` (§agent_spec 4.4).

---

## 3. DataStore — read-model extension (read-only)

`MeetingSummary` (`DataStore/DataStore+ReadModels.swift`) gains:

```
public let participants: [PersonData]   // organizer-first, deduped, capped (≤5)
public let participantCount: Int        // total distinct, drives "+N"
```

`PersonData` (already defined in the same file) is reused. `meetingSummaries(...)`
maps each meeting:

```
let ppl = ([meeting.organizer].compactMap { $0 } + meeting.participants)
let deduped = ppl.reduce(into: [Person]()) { acc, p in
    if !acc.contains(where: { $0.id == p.id }) { acc.append(p) }
}
participants = deduped.prefix(5).map { PersonData(id:$0.id, name:$0.name, email:$0.email) }
participantCount = deduped.count
```

Relationships are already loaded on the actor; mapping is cheap. **No schema
change, no migration, no write path.** Default for both fields when none:
`[]` / `0`. This touches neither `Transcription` nor `AudioCapture`, so the
manual-test gate is unaffected.

`CalendarEvent` already carries `organizer` + `attendees` + `attendeeCount`;
Upcoming needs no data change.

---

## 4. AppCore — shared timing constant

```
public enum MeetingTiming {
    /// ±window around event start where Join & Record is offered.
    public static let joinWindowSeconds: TimeInterval = 15 * 60
}
```

`HomeViewModel` uses this for the hero window. `EventPreviewViewModel` already
encodes the same `15*60`; repointing it at `MeetingTiming.joinWindowSeconds`
is a trivial optional cleanup to prevent drift (low-risk; does not change
meeting-detail UI/behavior). Either way the values must match.

---

## 5. HomeViewModel — derivations & actions

`HomeViewModel` (`HomeUI/HomeViewModel.swift`) gains a `urlOpener` injection
(mirroring `EventPreviewViewModel`) and the following. All time reads use
`core.minuteTick`.

```
public init(core: AppCore, urlOpener: @escaping (URL) -> Void = { _ in })
```

### 5.1 Greeting & date
```
var greeting: String     // hour(core.minuteTick): <12 "Good morning",
                         // <18 "Good afternoon", else "Good evening". No name.
var dateText: String     // "EEEE, MMMM d" of core.minuteTick (cached formatter)
```

### 5.2 Stat chips (derived from the upcoming set)
Synchronous, from data already in `core`. Semantic: "today" = events in the
local calendar day that are still upcoming/in-progress (we only have the
upcoming set in memory; already-ended earlier-today meetings are not counted —
see §10 confirm-item).

```
private var todaysMeetings: [CalendarEvent]   // displayedUpcoming where
  // isMeetingLike && Calendar.current.isDate(start, inSameDayAs: minuteTick)
var meetingsLeftText: String?    // "{n} meetings left today" (n = count); nil if no calendar access
var scheduledText: String?       // "{H}h {M}m scheduled" from Σ(end−start); nil if no access
var nextInText: String?          // "Next in {relativeTimeText}" of displayedUpcoming.first; nil if none
var showStatChips: Bool          // calendarAccess == .authorized
```
The view renders only the non-nil chips; hides the whole row when
`!showStatChips`.

### 5.3 Hero detection
```
var heroEvent: CalendarEvent? {
    guard let first = upcomingPreview.first else { return nil }
    let delta = abs(first.start.timeIntervalSince(core.minuteTick))
    return delta <= MeetingTiming.joinWindowSeconds ? first : nil
}
var heroIsRecordOnly: Bool   // heroEvent?.conferenceURL == nil
var recordDisabled: Bool     // core.recording.state.isRecording
```
The view: if `heroEvent != nil`, render the hero for the first row and ordinary
rows for `upcomingPreview.dropFirst()`; else ordinary rows for all.

### 5.4 Actions
```
func joinAndRecord(_ e: CalendarEvent) async {   // mirrors EventPreviewViewModel
    if let url = e.conferenceURL { urlOpener(url) }
    await core.startRecording(eventKey: e.id)
}
func openInCalendar(_ e: CalendarEvent) {        // date-fallback (no EK id on live events)
    if let url = URL(string: "ical://\(e.start.timeIntervalSinceReferenceDate)")
        ?? URL(string: "ical://") { urlOpener(url) }
}
```
`selectEvent` / `selectMeeting` / `showMeetings` stay as-is.

### 5.5 Avatar & names mapping (Home-side)
```
func avatarData(for e: CalendarEvent) -> (people: [AvatarPerson], total: Int)
  // people = ([organizer]+attendees) deduped by email||name → AvatarPerson;
  // total = max(people.count, e.attendeeCount)
func avatarData(for m: MeetingSummary) -> (people: [AvatarPerson], total: Int)
  // people = m.participants → AvatarPerson; total = m.participantCount
func pastSecondLine(for m: MeetingSummary) -> String
  // TimeFormatting.meetingSecondLine(date:duration:) + optional " · {names}"
  // names = first ~2–3 participant displayNames joined; omitted if none
```

---

## 6. HomeView — composition

Rebuild `HomeView` (`HomeUI/HomeView.swift`) per `agent_spec.md` §4.

- **Background:** outermost container `.background(Tokens.contentBackground.ignoresSafeArea())`
  — scoped to Home; `AppShellView` is not modified for this.
- **Centered column:** `GeometryReader` → `ScrollView` → content `VStack`
  constrained `.frame(maxWidth: 800)` then `.frame(maxWidth: .infinity)`, with
  `Spacer(minLength: 0)` above/below and `minHeight = proxy.size.height` so the
  column vertically centers when short and scrolls when tall.
- **Order:** greeting block → `StatChip` row → "UPCOMING" group (label + card)
  → "PAST MEETINGS" group (label + "See all ›" link + card).
- **Upcoming card:** manual `VStack(spacing:0)`; first row = hero
  (`AvatarCluster` 28pt + center stack + `JoinRecordButtonStyle` button +
  "View in calendar" link) when `heroEvent != nil`, else ordinary row
  (`AvatarCluster` 26pt + title/meta + `chevron.right`). `InsetDivider`
  between rows. Empty/permission states (Connect calendar / No meetings) keep
  current behavior, re-skinned into the card.
- **Past card:** ordinary rows (`AvatarCluster` 26pt + title + `pastSecondLine`
  + `chevron.right`); "No recordings yet" empty state re-skinned.
- The "Meet chip" uses `MeetingPlatformChip(platform: event.conferencePlatform)`
  rendered only when non-nil.

`AppShellViewModel` line 53 becomes
`HomeViewModel(core: core, urlOpener: { NSWorkspace.shared.open($0) })`.

---

## 7. Error handling

No new failure surfaces. URL/calendar opening is fire-and-forget through the
injected `urlOpener`. Recording starts via the existing `core.startRecording`,
which already owns its own error/permission handling. Calendar access uses the
existing `requestCalendarAccess` flow. Bad/empty data degrades gracefully:
missing participants → fallback avatar + omitted names; nil platform → no chip;
nothing upcoming → no hero, no "Next in" chip.

---

## 8. Testing strategy

Unit tests only (SwiftUI views remain preview-verified; no snapshot infra).

**DesignSystem — `AvatarTests` (new):**
- `avatarInitials`: "Sam Altman"→"SA"; one-word "Cher"→"CH"; empty→""; an
  email-as-name "sam@x.com"→two letters; non-ASCII first letters.
- `avatarColorIndex`: deterministic (same key → same index across calls);
  range `0..<16`; case/whitespace-insensitive; differs for distinct common
  emails (spot-check no collision among a sample set); email vs name keying.

**DataStore — extend `ContainerTests`/read-model tests:**
- `meetingSummaries` returns `participants` (organizer-first, deduped, ≤5) and
  correct `participantCount`; organizer-also-participant counted once; zero
  participants → `[]` + `0`.

**HomeUI — extend `HomeViewModelTests`:**
- greeting boundaries (set `minuteTick` to 09:00/14:00/20:00); `dateText`
  format.
- stat chips: `meetingsLeftText`/`scheduledText` over synthetic same-day vs
  other-day events; `nextInText` present/absent; `showStatChips` false when not
  authorized.
- hero: `heroEvent` non-nil when first upcoming within ±15m, nil at +16m and
  when list empty; `heroIsRecordOnly` true when no `conferenceURL`;
  `recordDisabled` reflects recording state.
- actions: `joinAndRecord` calls `urlOpener` with the conference URL **and**
  triggers `core.startRecording(eventKey:)` (spy core + spy opener);
  record-only path skips the URL; `openInCalendar` produces the expected
  `ical://<refInterval>` URL.
- mapping: `avatarData(for:)` dedup + `total`; `pastSecondLine` with and
  without names.

Use the existing `BiscottiTestSupport` harness + `PreviewAppCore`/spy patterns
already in `HomeViewModelTests` (inject a recording-capable spy core and a
capturing `urlOpener`).

---

## 9. Non-goals / out of scope (reaffirmed)
- No sidebar/toolbar/Record/search restyle (background colors only).
- No meeting-detail or Past-Meetings-list changes.
- No dark mode, no schema/migration, no new profile/user-name concept.
- No custom rendering pipeline — only composed native primitives, `Color`,
  gradients, `RoundedRectangle`, and a custom `ButtonStyle`.

## 10. Confirm-at-review defaults (carried from functional spec §9)
1. Stat chips show what's **left today** ("{n} meetings left today") — today's
   upcoming/in-progress meeting-like events; already-ended earlier-today
   meetings are not counted (only the upcoming set is in memory). Whole-day
   accuracy would need a calendar day-query — out of scope for this pass.
2. Preview caps unchanged (Upcoming 6, Past 4); participants mapped ≤5.
3. Avatars: 16-color palette rendered as a subtle gradient.
4. "View in calendar" → Calendar.app at the event date.
5. Empty/permission states behavior unchanged, re-skinned.
```
