---
status: complete
---

# UI Design — F · Sage design language

The canonical visual values for the reskin. The **architecture** doc describes
how these are implemented (semantic tokens, font registration, migration map);
this doc is the *what it looks like*. All values trace to the design agent's
"Rev F → F · Sage" guide, generalized from Home to the whole app.

Platform: macOS Tahoe, **light only**. Units are points. Colors are given as hex
+ opacity and as Swift `Color(red:green:blue:)` doubles (val/255) for precise
implementation.

---

## 1. Color palette

### Neutrals & surfaces (cool → warm ivory)

| Token (semantic) | Role | Value | Swift |
|---|---|---|---|
| `paper` | Content background | `#FBFAF5` | `Color(red: 0.984, green: 0.980, blue: 0.961)` |
| `cardFill` | Card fill | `#FFFFFF` | `.white` |
| `ink` | Primary text | `#1A1813` | `Color(red: 0.102, green: 0.094, blue: 0.075)` |
| `inkSecondary` | Secondary text | ink @ **54%** | `ink.opacity(0.54)` |
| `inkTertiary` | Tertiary text / chevrons | ink @ **34%** | `ink.opacity(0.34)` |
| `hairline` | Separator | ink @ **11%** | `ink.opacity(0.11)` |
| `neutralChip` | Neutral chip fill | ink @ **6%** | `ink.opacity(0.06)` |
| `cardStroke` | Card border (0.5pt) | `rgba(26,22,14,0.10)` | `Color(red: 0.102, green: 0.086, blue: 0.055).opacity(0.10)` |

### Window wall & sidebar

| Token | Role | Value |
|---|---|---|
| `wall` | Window backdrop behind the sidebar | radial gradient from top-left: `#E9E7E0` → `#E4E1D8` (≈55%) → `#DCD9CF`. Swift stops: `(0.914,0.906,0.878)` → `(0.894,0.882,0.847)` → `(0.863,0.851,0.812)`. |
| `sidebarTint` | Translucent ivory over the sidebar vibrancy | `rgba(250,249,244,0.82)` = `Color(red: 0.980, green: 0.976, blue: 0.957).opacity(0.82)` layered over the system sidebar material. |

> The wall + sidebar tint are **best-effort native**: applied where SwiftUI's
> `NavigationSplitView` / window background allow it without AppKit window
> surgery. If a faithful radial wall isn't reachable natively, a flat warm-grey
> (`#E4E1D8`) is an acceptable fallback. See architecture for the seam.

### Brand / accent (systemBlue → sage)

| Token | Role | Value | Swift |
|---|---|---|---|
| `sage` | **Primary / accent** | `#4E7D5C` | `Color(red: 0.306, green: 0.490, blue: 0.361)` |
| `accentWashStrong` | Selection background (selected nav) | sage @ **14%** | `sage.opacity(0.14)` |
| `accentWashSoft` | Soon-row / hero tint, speaker chip | sage @ **8%** | `sage.opacity(0.08)` |
| `sageButton` (optional gradient) | Record/hero button fill | `#5D9069 → #43704F` top→bottom; or flat `sage`. | stops `(0.365,0.565,0.412)` → `(0.263,0.439,0.310)` |

- **`liveGreen` is removed/aliased to `sage`.** The Meet/conference video icon
  and the "Next in" dot become sage. One green, used consistently.
- The app's accent/tint is set to `sage` app-wide (see architecture) so any
  residual `Color.accentColor` also resolves to sage; but call sites should
  prefer the named `sage` / wash tokens.

### Red — retained for "live/recording" only

| Token | Role | Value |
|---|---|---|
| `recordingRed` | Active-recording indicators (RecordingView dot, toolbar "Recording…" pill, Stop button) | **Unchanged — stays system `Color.red`.** (The design agent's `#EF3A22` is noted but we keep the current value per scope.) |

### Avatar palette — unchanged

The fixed 16-color initial-keyed `avatarPalette` is **kept verbatim** (order is
permanent). Avatar gradients stay colorful; they are *not* tinted sage.

---

## 2. Type system

### Families & the bundled weights

| Family | Bundled files (static TTF only — no webfonts/variable/italics) | Used weights |
|---|---|---|
| **SF Pro** | system (not bundled) | regular / medium / semibold |
| **Newsreader** (serif) | `NewsreaderDisplay-Medium.ttf` (+ `-Regular` if a lighter headline is wanted) | 500 (medium) |
| **JetBrains Mono** (mono) | `JetBrainsMono-Regular.ttf`, `JetBrainsMono-Medium.ttf` | 400, 500 |

Use **Newsreader _Display_** optical size (correct for large display text), not
Text/Caption. JetBrains Mono is rendered with **tabular figures** (its default)
to stop number jitter — this replaces today's `.monospacedDigit()` on SF Pro.

### The "Pressroom" rule (recap from functional spec §3)

- **SF Pro** — everything not explicitly serif/mono below.
- **Newsreader** — only: Home greeting, Onboarding step headline(s), large
  empty-state headlines we control (the `ContentUnavailableView` titles).
- **JetBrains Mono** — all numbers/timestamps/durations/counts + uppercase
  kicker labels.

### Type ramp (semantic tokens → family/size/weight/tracking)

The **size/weight scale is inherited** from the current app; only families and
the noted tweaks change. Tokens marked **(unchanged)** keep today's SF Pro.

| Element | Token | Rev F (from) | F · Sage (to) |
|---|---|---|---|
| Greeting | `serifGreeting` | SF Pro 32 bold, tracking −0.6 | **Newsreader Display ~32, weight 500, tracking −0.32** |
| Onboarding headline | `serifHeadline` | SF Pro `.title2` semibold | **Newsreader Display (same size), weight 500** |
| Empty-state headline (ContentUnavailableView title) | `serifHeadline` | system title | **Newsreader Display, weight 500** (via label closure) |
| Date line | `monoDate` | SF Pro 15 reg | **JetBrains Mono 15 reg** |
| Countdown ("in 6m") | `monoMetaMedium` + `sage` | SF Pro 12.5 med, blue | **JetBrains Mono 12.5 med, sage** |
| Time ("9:00 AM"), past meta ("Today · 32m") | `monoMeta` | SF Pro 12.5 | **JetBrains Mono 12.5** |
| Stat-chip value | `monoStat` | SF Pro 12.5 med | **JetBrains Mono 12.5 med** |
| "+N" overflow badge | `monoBadge` | SF Pro ~9 med | **JetBrains Mono (same size) med** |
| Sidebar meeting time | `monoMeta` | SF Pro 13 + monodigit | **JetBrains Mono 13** |
| Recording elapsed counter | `monoElapsed` | SF Pro largeTitle monodigit | **JetBrains Mono largeTitle, weight 500** |
| Audio-transport times | `monoCaption` | SF Pro caption + monodigit | **JetBrains Mono caption** |
| Kicker labels ("UPCOMING", "PAST MEETINGS", sidebar section) | `monoKicker` | SF Pro 11.5 semibold, tracking +0.5, uppercase | **JetBrains Mono 10.5, weight 500, uppercase, tracking +1.47 (≈ +0.14em)** |
| Hero title | `heroTitle` | SF Pro 16 semibold | (unchanged) |
| Row title | `rowTitle` | SF Pro 14.5 medium | (unchanged) |
| Descriptions / notes / prose meta / links text | `metaText` | SF Pro 12.5 | (unchanged) |
| Wordmark ("Biscotti") | — | SF Pro 13 semibold | (unchanged — **SF Pro**, not serif) |
| Body, button labels, search, participant names | — | SF Pro | (unchanged) |

> **Empty-state nuance:** Home's small in-card empty texts ("No recordings yet",
> "No meetings coming up") are **not headlines** — they stay SF Pro `metaText`.
> Serif applies to the **large** empty-state headlines, i.e. the
> `ContentUnavailableView` titles (Meeting list "No Recordings", AppShell "No
> Meeting Selected"), rendered via the `ContentUnavailableView { label }` closure
> with `serifHeadline`. Description text stays SF Pro. If serif reads poorly in a
> real run, falling back to SF Pro here is acceptable.

---

## 3. Surfaces & depth (unchanged rules, warm values)

- **Card:** white fill, radius 12, **0.5pt** `cardStroke` hairline, whisper
  shadow (`black @ 5%, radius 1.5, y 1`) — composition unchanged; only the
  stroke color warms.
- **Inset dividers:** `hairline`, 0.5pt, 14pt leading inset (unchanged).
- **Content background:** `paper` (ivory) replaces the cool near-white.
- **Radii:** card 12, button/search/chip 8, stat chip 7, meet chip 6, circles —
  all unchanged.

---

## 4. Reusable component specs (visual)

Each lists what changes. Structure/metrics unchanged unless noted.

- **Avatar / AvatarCluster:** gradients unchanged. "+N" badge → `monoBadge`,
  text color `inkSecondary`; badge fill `inkSecondary.opacity(...)` warm. White
  2pt stacked ring unchanged. `RecordingAvatar` mic circle neutral → warm grey.
- **StatChip:** value text → `monoStat`, `inkSecondary`. Default icon tint →
  `sage` (calendar) or `sage` ("next" dot). Fill `neutralChip` (warm).
- **UpcomingEventRow:** title SF Pro (unchanged); time → `monoMeta`,
  `inkSecondary`; platform badge fill warm neutral.
- **MeetingPlatformChip:** video icon → `sage` (was liveGreen); label SF Pro;
  chip fill warm neutral (`ink.opacity(0.06)`).
- **HomeCardModifier / InsetDivider:** `cardStroke` + `hairline` warm.
- **JoinRecordButtonStyle:** fill → `sage` (flat, or optional `sageButton`
  gradient) with the existing top-highlight; label SF Pro white (unchanged).
- **TranscriptSegmentRow:** speaker chip background → `accentWashSoft` (sage);
  speaker label SF Pro semibold caption (unchanged); body SF Pro.
- **Banner / StatusRow:** warning amber + error red icons unchanged (status
  semantics, not brand). `StatusRow` success checkmark **→ sage** (was system
  green) to match the unified success color. Body text → `inkSecondary`.
- **AudioTransport:** elapsed/total times → `monoCaption`; controls unchanged.
- **CalendarContextBlock:** neutrals warm; calendar color dot uses the real
  calendar hex (unchanged); text → `inkSecondary`.
- **VersionPicker:** unchanged (system Menu); date text reads as data but lives
  in a system menu — leave SF Pro.
- **RecordButton (currently unused):** its dot represents the *idle* Record
  affordance → recolor dot to **sage** (per the idle = sage rule). Low priority;
  acceptable to leave or delete since unreferenced — but keep it consistent if
  touched.

---

## 5. The two additive elements (visual spec)

### 5a. Sidebar brand lockup (new)

At the top of the sidebar (`AppShellView.sidebar`), above the Home row, add a
quiet brand lockup:

```
[ lock.shield.fill ]  Biscotti
```

- Icon: SF Symbol `lock.shield.fill`, **sage**, ≈ 16–18pt, baseline-aligned to
  the wordmark.
- Wordmark: "Biscotti", **SF Pro semibold** ≈ 15pt, `ink`, near-zero tracking.
- Padding consistent with existing sidebar rows; it is **non-interactive**
  (label, not a button) — adds no behavior.
- Mirror the same sage `lock.shield.fill` into the existing **Home footer**
  lockup (`HomeFooter`), placed left of / above the "Biscotti" text, so the
  footer and sidebar share one brand mark. Footer wordmark stays SF Pro; tagline
  "Total recall, total privacy." stays SF Pro `inkTertiary`.

### 5b. Idle Record → sage

In the toolbar (`AppShellView`):

- **Idle "Record"** button: `record.circle` icon + tint → **sage** (the `.bordered`
  control tinted sage). Reads "ready to record."
- **Active "Recording… {counter}"** button: unchanged — `.borderedProminent`,
  `recordingRed`, counter → `monoMeta` (mono). Reads "live."

RecordingView (full-screen) is unchanged: red pulsing dot + `monoElapsed`
counter + red Stop button.

---

## 6. Resolved micro-decisions (from review)

- **Success color → sage** everywhere it was a success/granted green
  (`StatusRow`, onboarding permission checkmarks). Status amber/error red on
  `Banner` stay (they're status semantics, not brand).
- **Menu bar dropdown** keeps the **native macOS menu look on purpose** (not
  restyled). The status-bar label keeps icon + mono elapsed text.
- **ContentUnavailableView** titles get `serifHeadline` via the label closure;
  Home's small in-card empties stay SF Pro.
- **Onboarding** step headline(s) → `serifHeadline`; the rest of onboarding is
  SF Pro + warm neutrals + sage success checkmarks.
