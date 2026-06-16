---
status: complete
---

# UI Design: Update Meeting Screen

The **visual/layout contract** for the redesigned `MeetingDetailView`. Behavior
lives in `functional_spec.md`; this doc is "how it looks" — token mapping,
metrics, and per-section visual specs. Everything maps onto the existing
`DesignSystem` (`Tokens`, `Color+Theme`, `Font+Theme`, `Avatar`); we add no new
colors or fonts.

The design agent's bespoke `Pal` tokens and pixel values are **translated** to
our system below. Where the agent's value and ours differ, we prefer the
**existing token** for app-wide consistency (and note it).

---

## Token mapping (design agent → ours)

| Design `Pal` | Our token | Value |
|---|---|---|
| `accent` | `Color.sage` / `Tokens.liveGreen` | sage #4E7D5C |
| `label` | `Color.ink` | warm ink #1A1813 |
| `label2` | `Color.inkSecondary` | ink @ 54% |
| `label3` | `Color.inkTertiary` | ink @ 34% |
| `content` (pane bg) | `Tokens.contentBackground` (`.paper`) | ivory #FBFAF5 |
| `card` | `Tokens.cardFill` | white |
| `cardBdr` | `Color.cardStroke` | warm ink @ 10%, 0.5pt |
| `sep` | `Color.hairline` / `Divider` | ink @ 11% |
| `fill` (soft control) | `Tokens.neutralChip` | ink @ 6% |
| selection wash | `Tokens.accentWashStrong` | sage @ 14% |

## Typography roles

| Role | Helper | Used for |
|---|---|---|
| Serif display | `Font.biscottiSerif(27)`, tracking −0.27 | the H1 meeting title **only** |
| Mono | `Font.biscottiMono(…)` / `.monoMeta` (12.5) / `.monoCaption` (10) | every timestamp, duration, date, URL |
| Mono kicker | `.kicker()` (`.monoKicker` 10.5 + uppercase + tracking 1.47) | definition-list labels, section kickers |
| System (SF Pro) | `.system(…)` | all other body text, buttons, menus, transcript prose, speaker names |

**Tabular figures:** all mono numerics use `.monospacedDigit()` so digits don't
jitter during playback.

> The bundled monospace is **JetBrains Mono** (via `biscottiMono`), not IBM Plex.
> The serif is **NewsreaderDisplay** (via `biscottiSerif`).

## Scroll model

**Loading state:** while the meeting data is loading, the pane shows a single
centered `ProgressView("Loading…")` spinner — no partial skeletons. Once loaded,
the real content renders.

One outer `ScrollView`; the Notes editor is sized to fill the height left below
the chrome **with no minimum floor**, so the chrome looks pinned when it fits and
the pane scrolls **only when content genuinely exceeds the viewport**:

```
ScrollView:
  chrome (measured height): header · calendar card · transport · tab bar
  ─────────────────────────────────────────────────────────────────────
  Notes tab      → MarkdownEditor, height = max(0, paneH − chromeH − padding),
                   scrolls internally  →  chrome looks pinned when it fits
  Transcript tab → selectable Text, minHeight = max(0, paneH − chromeH − padding),
                   grows; the outer ScrollView scrolls it (chrome scrolls away)
```

This refines the design agent's "whole pane scrolls as one" into a native-reality
call: the pinned markdown engine exposes no content-height API, so we size the
editor explicitly. Net effect — **no double scroll**, empty/short content fits
the viewport without forcing a scroll, and normal scroll-to-read for long
transcripts. See `architecture.md` for the `ChromeHeightKey` measurement.

**Performance note:** the `AttributedString` for the transcript is cached by
transcript ID + `canPlay` in the view model. It is only rebuilt when the
underlying data changes, not on every SwiftUI render — this avoids a ~1s
synchronous build for long transcripts.

## Layout metrics

- **Pane background:** `Tokens.contentBackground` (ivory), ignoring safe area.
- **Content column:** left-aligned, **max width 760pt** (the design's value; note
  Home uses 800 — kept distinct per the design, trivially alignable later).
- **Page insets:** `24` top/bottom, `32` leading/trailing (reuses Home's
  `homeVerticalPadding` / `homeHorizontalPadding` for consistency).
- **Section spacing:** the 8pt grid (`Tokens.spacingSM/MD/LG`). Major sections
  separated by `spacingMD`(16)–`spacingLG`(24).
- **Card radius:** `Tokens.cardRadius` (12) for the calendar + transport cards.
- **Button radius:** `Tokens.buttonRadius` (8); pills use `Capsule`.
- **Card stroke:** `Color.cardStroke` at 0.5pt; card fill `Tokens.cardFill`.

---

## Section-by-section visual spec

### Header
```
Polarity Labs Dive                                            (•••)
Yesterday at 4:18 PM   ·   32 min   ·   ◐ Google Meet
```
- **Title** — inline-editable `TextField`, `.plain` style, `Font.biscottiSerif(27)`,
  `.foregroundStyle(.ink)`, `tracking(-0.27)`, tight line spacing. Fills width.
- **"…" menu** — trailing `Menu` with `Image(systemName: "ellipsis.circle")`
  at `.font(.system(size: 18, weight: .light))`, `.inkSecondary`.
  Uses `.menuStyle(.button)` + `.buttonStyle(.plain)` so the label renders
  as a plain view that honors `.font()` — `.borderlessButton` clamps the
  glyph to a fixed control metric (FB9754368). `.menuIndicator(.hidden)`,
  `.fixedSize()`.
- **Meta line** — `HStack(spacing: spacingSM)`, `.monoMeta` (`.inkSecondary`),
  middle-dot `·` separators in `.inkTertiary`:
  - relative date/time · duration · **source pill**.

### Source pill
- `Label(platform, systemImage: "video.fill")`, `.font(.system(size: 11, weight:
  .medium))`, icon `.foregroundStyle(.sage)`, text `.inkSecondary`,
  `Tokens.neutralChip` background, `Capsule()` clip, height ~19,
  `.padding(.horizontal, 7)`. Shown only when a conference platform is known.

### "…" overflow menu
Native `Menu` items (SF Symbols), order:
- Reveal recording in Finder — `folder` *(hidden if no audio files present)*
- Re-transcribe — `arrow.triangle.2.circlepath` *(only when `canReTranscribe`)*
- — divider —
- Link Calendar Event… — `calendar.badge.plus` *(only when no event linked)*
- Change Calendar Event… — `calendar` *(only when linked)*
- Unlink Calendar Event — `calendar.badge.minus` *(only when linked)*
- — divider —
- Delete Meeting… — `trash`, `role: .destructive` (native red — never hand-colored)

### Calendar info card  *(only when an event is linked)*
A rounded card: `RoundedRectangle(cornerRadius: 12)` fill `Tokens.cardFill`,
`.overlay` 0.5pt `Color.cardStroke`, inner padding `spacingMD`. Inside,
`VStack(alignment: .leading)`:

- **Row A** — `HStack(spacing: spacingSM)`:
  - **Avatar stack** — reuse `AvatarCluster` (size `Tokens.avatarSize` 26,
    stacked white ring) from attendees; "+N" overflow built in.
  - Attendee summary `Text` (~13pt): organizer name `.ink` `.medium`, others
    `.inkSecondary`.
  - `Spacer()`
  - **"Open in Calendar"** — soft secondary button: `Label("Open in Calendar",
    systemImage: "calendar")`, `Tokens.neutralChip` fill, radius 8, label `.ink`,
    icon `.inkSecondary`, `.controlSize(.small)`.
- **Divider** (`Color.hairline`), `.padding(.vertical, spacingSM)`.
- **Row B — custom tappable disclosure** (whole header line toggles; not
  stock `DisclosureGroup`). Rotating chevron (`chevron.right`, 11pt semibold,
  `.inkSecondary`), system rotation animation:
  - **Collapsed:** chevron + "Event Details" (`.system(13, .medium)`, `.ink`) +
    WHEN preview text (`.monoMeta`, `.inkSecondary`, `.lineLimit(1)`,
    `.truncationMode(.tail)`).
  - **Expanded:** preview hidden; a definition list `Grid(alignment:
    .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 11)`,
    label column content-sized (`.gridColumnAlignment(.leading)`):

    | dt (`.kicker()`, `.inkTertiary`) | dd (`.system(13)`, `.ink`/`.inkSecondary`) |
    |---|---|
    | WHEN | date/time range, `.monoMeta`, `.textSelection(.enabled)` |
    | WHERE | `video` icon (`.sage`) + platform + `.monoMeta` URL; and/or location, selectable |
    | INVITED | "Steve (organizer) · Alex · Jay · +2", `.textSelection(.enabled)` |
    | DESCRIPTION | wrapped notes paragraph, `.inkSecondary`, maxWidth ~460, `.textSelection(.enabled)` |

### Audio transport card
A rounded card (`cornerRadius` 12, `cardFill`, 0.5pt `cardStroke`, padding
`spacingSM`–`spacingMD`). `HStack(spacing: spacingSM)`:
- **Play/pause** — `Button`, `Image(isPlaying ? "pause.fill" : "play.fill")`
  ~15pt `.ink`, inside a 30pt `Circle` that fills `Tokens.neutralChip` on hover,
  `.buttonStyle(.plain)`.
- **Elapsed** — `.monoCaption`, `.monospacedDigit()`, `.inkSecondary`.
- **Scrubber** — `Slider`, `.tint(.sage)` (native white knob + sage fill + rail).
- **Total** — `.monoCaption`, `.monospacedDigit()`, `.inkSecondary`.
- **Speed `Menu`** — soft-secondary styled (`Tokens.neutralChip`, height ~26,
  radius 8, trailing chevron) showing the current rate "1×"; options 0.5 / 1 /
  1.25 / 1.5 / 2×.
- **Disabled** (`!canPlay`): "Audio not available" label + disabled speed menu.
  Only shown after loading completes; while loading, the transport is hidden
  behind the unified loading spinner. No download button.

### Tab row — segmented control (+ version picker + copy)
`HStack`:
- **`Picker`** `.pickerStyle(.segmented)` `.fixedSize()` — `Transcript` |
  `Notes`, left-aligned, content-width. Default `.transcript`.
- `Spacer()`
- **On the Transcript tab:** the **`VersionPicker`** (only when
  `versions.count > 1`).
- **Always visible (both tabs):** a **"Copy"** button (`Label("Copy",
  systemImage: "doc.on.doc")`, `.borderless`, `.controlSize(.small)`,
  `.inkSecondary`). On the Transcript tab it copies the transcript; on the
  Notes tab it copies the notes. Hidden when there is nothing to copy
  (empty transcript / empty notes).
- Padding: `.top, spacingLG` · `.bottom, spacingMD`.

### Transcript (Transcript tab, ready state)
One `Text(AttributedString).textSelection(.enabled)`, `lineSpacing` comfortable.
Per turn, in the attributed string:
- **Speaker name** — `.semibold`, tinted by stable per-speaker color
  (`Tokens.avatarPalette[avatarColorIndex(forKey: speakerLabel/ID)]`).
- two spaces, **timestamp** — `MM:SS` (`H:MM:SS` if ≥1h), `Font.biscottiMono`
  ~12, `.inkTertiary`, rendered as a clickable link (custom `biscotti://seek?t=`
  URL). Plain (non-link) when `!canPlay`.
- newline, **utterance** — system ~14pt, `.inkSecondary`.
- blank line between turns.

```
Steve  00:14
Let's kick off the Polarity review and look at retention.

Alex   00:31
Sounds good — first the weekly actives, then the cohort curve.
```

Other states (same tab): processing → centered `StatusRow`; failed → `Banner`
+ optional Retry. Two distinct empty states (`.system(size: 15)`):
- **Not transcribed** (`versions` empty): "No transcript yet" + "Transcribe now"
  button (when `canReTranscribe`).
- **Transcription empty** (transcript exists but `segments` empty):
  "Transcription empty" — no Transcribe action (it already ran).
Copy hidden for both empty states.

**Version picker:** shows a checkmark next to the currently displayed version.

### Notes (Notes tab)
`MarkdownEditor` bound to `viewModel.notes`, **filling the remaining viewport**
and scrolling internally (`.frame(height: max(0, paneH − chromeH − padding))`).
Placeholder "Add notes…". Click anywhere in the notes area — including the empty
space below the placeholder — to focus the editor (via a `TextViewFocusForwarder`
`NSViewRepresentable` background that walks the view hierarchy to find and focus
the underlying `NSTextView`). Bottom page padding (`homeVerticalPadding`) ensures
the notes don't touch the window edge. Subtle 0.5pt `cardStroke` rounded rect
border. No `MarkdownEditorUI` change.

---

## Page wireframe (Transcript tab)

```
┌───────────────────────────────────────────── 760pt ──┐
│ Polarity Labs Dive                              (•••) │  ← serif H1 + … menu
│ Yesterday at 4:18 PM · 32 min · ◐ Google Meet         │  ← mono meta + pill
│                                                       │
│ ┌───────────────────────────────────────────────────┐│
│ │ ◍◍◍ +2  Steve (organizer), Alex…    [Open in Cal] ││  ← calendar card
│ │ ───────────────────────────────────────────────── ││
│ │ ▶ Event Details  Yesterday, Jun 11 · 4:18–4:50 PM   ││  ← tappable disclosure
│ └───────────────────────────────────────────────────┘│
│ ┌───────────────────────────────────────────────────┐│
│ │ ▶  ──●────────────────  3:11 / 32:00      [ 1× ▾ ] ││  ← transport + speed
│ └───────────────────────────────────────────────────┘│
│                                                       │
│ [ Transcript | Notes ]                  [v ▾] [⧉ Copy]│  ← tabs + version + copy
│ ═════════════════════════════════════════════════════ │  ← pin boundary (above: fixed)
│ Steve  00:14                                  ▲ scrolls │
│ Let's kick off the Polarity review…                   │  ← one selectable block
│                                                       │
│ Alex   00:31                                          │
│ Sounds good — first the weekly actives…               │
└───────────────────────────────────────────────────────┘
```

---

## Reused components

- `Avatar` / `AvatarCluster` / `AvatarPerson` (calendar card attendee stack).
- `Font.biscottiSerif` / `biscottiMono`, `.kicker()`, the `Tokens` palette/grid.
- `AudioTransport` (restyled to a card + speed menu).
- `VersionPicker`, `StatusRow`, `Banner` (repositioned/reused).
- `MarkdownEditor` (used at fill height — no change to the module).
- The existing event-picker sheet (`EventPickerSheet`) for Link/Change.

## New visual pieces

- A **source pill** view (capsule label).
- A **selectable transcript** view + its `AttributedString` builder
  (speaker-color, mono seek-links).
- A **calendar info card** (restyle of `CalendarContextBlock` into card +
  custom tappable disclosure with definition list) — or a new view superseding it.
- A small **speed menu** styled as the soft secondary control.

## Accessibility / interaction notes

- Timestamp links are keyboard/VoiceOver actionable (they're real links).
- The serif title remains a standard editable field (VoiceOver: text field).
- `role: .destructive` Delete gets the system's red + confirmation dialog.
- Hover affordances (play button fill, menu tint) are cosmetic, not required for
  operation.
