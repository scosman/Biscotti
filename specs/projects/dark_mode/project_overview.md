---
status: complete
---

# Dark Mode

Biscotti generally failed at supporting dark mode. Many backgrounds are hardcoded
light colors, so in dark appearance the app ends up with white text on light
backgrounds (and other unreadable combinations).

A design agent produced a "migrate to dark mode" plan (the **Dark Mode Spec**,
embedded below). The human has visually reviewed its color choices and approved
them. The catch: the design agent isn't a coding agent and never saw the
codebase. Its spec is based on *comps* of our designs, and the actual app has
moved beyond those comps in places. So this project's job is to figure out what
from the design spec makes sense to port in, grounded in the real code.

## Guiding rules

- **The codebase behavior always trumps the design docs.** Where the shipped code
  diverges from the comps, the code wins — we keep those decisions.
- **This is a color-mapping exercise for dark mode, not a feature change.** No
  adding backgrounds/highlights where there wasn't one. It's about selecting the
  appropriate migration for what's already there.
- **Zero changes to light-mode rendering.** The code may change, but light mode
  must produce the same pixels, byte-for-byte.
- **Make it reusable.** Create the needed palette/token plumbing so that going
  forward it's just a matter of attaching the right color to a design and dark
  mode is automatic — no per-view conditionals.
- Dark mode **follows the system appearance** — no in-app toggle.

## Codebase grounding (verified before this overview)

- Colors are already centralized: `DesignSystem/Color+Theme.swift` (semantic
  `Color` + `NSColor` extensions, defined as hardcoded sRGB literals) and
  `DesignSystem/Tokens.swift` (a `Tokens` enum aliasing those colors plus
  typography/spacing/radii). The app is **well-tokenized** — there are **zero**
  inline `Color(red:…)` literals in feature code.
- These tokens are static literals, so they do **not** adapt to appearance — that
  is the root cause of the dark-mode failure.
- The app does **not** force a color scheme anywhere (`preferredColorScheme`),
  so once the tokens adapt, dark mode largely "just works."
- A small set of hardcoded sites need individual attention: `.white`/`.black`
  used in button styles, avatar rings, shadows, and gradients; one
  `.ultraThinMaterial`; one `NSColor` use in the markdown editor; the flat
  `Color.wall` window backdrop and `Color.sidebarTint` sidebar.
- `Color(hex:)` (calendar colors) and `Tokens.avatarPalette` (colorful avatars)
  are **data/identity colors** and are intentionally **not** migrated — they read
  on both appearances.

## The Dark Mode Spec (design agent's plan — source for dark *values*)

> Note: this is the design intent. Where it describes structure that differs from
> the shipped code (e.g. it calls the window backdrop a radial gradient; the code
> uses a flat fill), the **code wins** and we port only the color *values*.

```
# Biscotti — Dark Mode Spec

How to add dark mode to Biscotti. Identity is unchanged: **F · Sage + Pressroom**
(warm ivory paper → warm near-black ink, sage primary, Newsreader serif,
IBM Plex Mono numbers/kickers, colorful avatars). Direction chosen: **B · Deep Ink**.

Platform: SwiftUI, macOS Tahoe. Dark mode **follows the system appearance** — no
in-app toggle. Units are points.

Visual references in this project:
- `Biscotti Dark Mode.html` — Home, Deep Ink beside the light Rev F.
- `Biscotti Dark Mode — Screens.html` — Meeting Detail pane, Active Recording, and the semantic-color swatches.

---

## 0. The one principle: this is a palette, not a parallel UI

Dark mode is implemented **entirely as token values that change with appearance.**
There are **no `if colorScheme == .dark` branches in view code**, no duplicated
layouts, no per-component dark variants.

Mechanism:

- Every color is a **semantic token** with a *role* (`accent`, `card`, `read`,
  `alert`…), defined in **one place** as a two-value entry — an **asset-catalog
  color set** with an **"Any Appearance"** value and a **"Dark"** value. macOS
  resolves it automatically. Views reference `Pal.card` and never know the mode.
  - (If you model the palette as a Swift struct instead of the catalog, allow
    **exactly one** `@Environment(\.colorScheme)` switch at the palette layer.
    Do not let `colorScheme` leak into individual views.)
- **Layout, spacing, type, radii, avatars, and structure are identical** across
  modes. Only color/elevation token *values* differ.

### Guarantee: light mode does not change
Every **new** token below has its **light value set equal to the literal it
replaces**, so introducing it is a pure refactor — light renders byte-for-byte
the same. Only the **Dark** column diverges. Do **not** change any light value as
part of this work (including light-mode reading contrast).

---

## 1. Three new semantic tokens (the only non-mechanical change)

The light system used one token where dark needs two. Add these; in light they
collapse to an existing value (no visible change), in dark they diverge.

| New token | Light value (unchanged behavior) | Dark value | Why dark needs it |
|---|---|---|---|
| **`accentFill`** | `#4E7D5C` (= `accent`) | **`#56906A`** | A *brightened* sage carries text/icons for contrast on dark, but a button **fill** that bright would fail white-label contrast. Fills use the deeper sage; text uses the bright one. |
| **`read`** | `label2` = `#1A1813` @ 54% (= today's transcript body) | **`#F7F2E8` @ 75%** | 54% white is fatiguing for long-form reading on near-black. Body prose lifts; meta/labels stay at the secondary level. |
| **`elevatedFill`** | `#FFFFFF` (= today's white buttons) | **`#1A170F`** (= `card`) | The "white-fill" light buttons (Stop & Save, header REC pill) can't stay white on dark; their fill becomes the elevated card surface. |

**Refactor required (one-time, light-neutral):** repoint these usages from the
hardcoded literal to the token —
- button **fills** currently using `accent` → `accentFill`.
- **transcript & notes body** text currently using `label2` → `read`.
- **Stop & Save** and the **recording header pill** fills currently using
  `white`/`#fff` → `elevatedFill`.
- any **hover/soft-fill** literals (`Color.black.opacity(0.045–0.06)`,
  `rgba(26,24,19,.05)`) → the `hover` / `fill` tokens in §2.

Everything else is already token-driven.

---

## 2. Full token table — light → dark

> Light column = the shipped **F · Sage + Pressroom** values (source of truth;
> do not edit). Dark column = Deep Ink.

### Surfaces & ink
| Token | Light | Dark |
|---|---|---|
| `windowWall` (backdrop) | `radial #E9E7E0 → #E4E1D8 55% → #DCD9CF` | `radial #16140E → #110F09 55% → #0B0A06` |
| `content` (pane bg) | `#FBFAF5` | **`#100E09`** |
| `sidebar` (over vibrancy) | `rgba(250,249,244,.82)` | **`rgba(20,18,13,.74)`** (over dark vibrancy) |
| `card` | `#FFFFFF` | **`#1A170F`** |
| `cardTop` (raised gradient top, e.g. record console) | `#FFFDFB` | **`#211D14`** |
| `elevatedFill` (white-button fill) | `#FFFFFF` | **`#1A170F`** |
| `cardBorder` | `rgba(26,22,14,.10)` | **`rgba(247,242,232,.12)`** |
| `cardShadow` | `0 1px 3px rgba(40,34,20,.05)` | **`0 1px 2px rgba(0,0,0,.40)`** |
| `windowHairline` | `rgba(0,0,0,.18)` | **`rgba(255,255,255,.11)`** |
| `ink` (primary) | `#1A1813` | **`#F7F2E8`** |
| `ink2` (secondary/meta) | `rgba(26,24,19,.54)` | **`rgba(247,242,232,.58)`** |
| `ink3` (tertiary/chevron) | `rgba(26,24,19,.34)` | **`rgba(247,242,232,.36)`** |
| `read` (long-form body) | `rgba(26,24,19,.54)` | **`rgba(247,242,232,.75)`** |
| `separator` | `rgba(26,24,19,.11)` | **`rgba(247,242,232,.12)`** |
| `chip` (neutral chip) | `rgba(26,24,19,.06)` | **`rgba(247,242,232,.07)`** |
| `fill` (soft control fill) | `rgba(26,24,19,.05)` | **`rgba(247,242,232,.06)`** |
| `hover` | `rgba(0,0,0,.045)` | **`rgba(247,242,232,.06)`** |

### Sage (primary)
| Token | Light | Dark |
|---|---|---|
| `accent` (text/icon/link/timestamp) | `#4E7D5C` | **`#86C295`** |
| `accentFill` (button fill, white label) | `#4E7D5C` | **`#56906A`** |
| `accentWash` (selection / soon-row / soft btn) | `rgba(78,125,92,.08–.16)` | **`rgba(134,194,149,.12–.16)`** |
| `accentTrack` (scrubber/progress fill) | `#5D9069 → #43704F` | **`#5E9A6F`** |
| `recordIdle` (idle Record pill gradient) | `#5D9069 → #43704F` | **`#5F9D70 → #3F6F4D`** |
| `recordRing` | `rgba(78,125,92,.16)` | **`rgba(134,194,149,.16)`** |

### Alert red (recording · errors · destructive)
| Token | Light | Dark |
|---|---|---|
| `alert` (dot/mark/icon) | `#C9402B` | **`#E5604A`** |
| `alertText` (red text on bg) | `#B23320` | **`#F08A78`** |
| `alertGrad` (recording-pill gradient) | `#DB5740 → #BE331E` | **`#E5604A → #C73D27`** |
| `alertWash` (error/banner/sidebar-row bg) | `rgba(201,64,43,.09)` | **`rgba(229,96,74,.13)`** |
| `alertBorder` (outline/ring) | `rgba(201,64,43,.28–.32)` | **`rgba(229,96,74,.36)`** |

### Amber warning (last 5 min — never red)
| Token | Light | Dark |
|---|---|---|
| `amberWash` (chip bg) | `rgba(232,161,58,.18)` | **`rgba(232,161,58,.15)`** |
| `amberKicker` (label) | `#996A12` | **`#D9A53A`** |
| `amberValue` (value text) | `#7D540A` | **`#F0C04A`** |
| `amberDot` (pulsing dot) | `#E8A13A` | **`#E8A13A`** (reads in both) |

> The amber **fully flips polarity**: light is dark-brown text on a light amber
> wash; dark is bright-amber text on a low-alpha wash. It's the one token where
> the dark value isn't simply a lightened light value — see the swatch.

---

## 3. Elevation inverts

In light, cards are pure white **lighter** than the ivory page, with a hairline +
whisper shadow. In dark you **cannot** lift with white, so:

- **Background is the darkest layer** (`content` `#100E09`).
- **Cards sit *above* it as a lighter warm surface** (`card` `#1A170F`) + the
  `cardBorder` hairline. The lift *is* the card; **shadows recede** (they do
  little on dark — keep them but don't lean on them).
- Doubly-raised surfaces (record console, soft cards that use a `#fff→#fffdfb`
  gradient in light) use `card → cardTop`.
- Stacked-avatar separator rings and the `+N` badge ring use `card` (already
  token-driven) so they read against whatever surface they're on.

No shadow values carry over literally — use the `cardShadow` token.

---

## 4. Per-surface notes

Only the points that need care. Everything else is the token swap.

### Home
Pure palette swap. Greeting serif, mono kickers/timestamps, stat chips, soon-row
`accentWash`, colorful avatars — all unchanged structurally.

### Meeting Detail pane
- **Transcript / Notes body → `read`** (the brighter token). Speaker name stays
  `ink`, timestamp stays `ink3`/mono. This is the main reason `read` exists.
- **Audio scrubber:** native `Slider` — let it follow appearance; its tint is
  `accent`(text-bright) and the filled portion reads as `accentTrack`. The rail
  is the system track on dark.
- **Segmented control** (`Picker(.segmented)`) and **`role: .destructive`**
  Delete: **native — do not restyle.** They adapt to dark automatically.
- **Source pill / soft "Open in Calendar" button:** `chip` / `fill` + `ink2`.
- **"…" menu / popovers:** dark glass — `rgba(30,27,20,.97)` + `cardBorder`
  hairline; hover row uses `accentFill` with white text (unchanged rule).

### Active Recording ("E · Quiet")
- **RECORDING badge:** dot/halo `alert`; label `alertText`, mono.
- **Stop & Save (light button):** fill `elevatedFill` (now the card surface, not
  white), `0.5pt` `alertBorder` outline, `alert` stop-square, `alertText` label.
- **Header REC pill (live):** fill `elevatedFill`, `alertBorder` outline,
  pulsing `alert` dot, `alertText` mono timer. (Idle Record pill = `recordIdle`
  sage gradient, static.)
- **Sidebar "RECORDING NOW" row:** `alertWash` fill + `alertBorder` inset.
- **Time chips:** Elapsed = neutral `fill`. **Left ≤ 5:00** → `amberWash` bg,
  `amberKicker` label, `amberValue` value, pulsing `amberDot`. Never red.
- **Note composer / Add note / note timestamps:** sage — `accentWash` button,
  `accent` timestamps; note body uses `read`.

### Upcoming Event detail
Palette swap. Auto-record card = `accentWash` over `card`; toggle on = `accent`,
off = neutral. Disclosure triangle is native. Destructive menu item = `alertText`
/ `alert`, hover `alert` fill.

### Onboarding
Palette swap. Progress lines/bars/dots: track = `separator`/neutral on dark,
fill = `accentTrack`/`accent`. Permission checklist/cards = `accentWash` + `accent`
checks. Mastheads/footer lockups keep the sage `lock.shield.fill`.

---

## 5. Native vs. custom — the rule

- **Native controls follow the system. Don't touch them in dark:** segmented
  `Picker`, `Slider`, `Menu`, `DisclosureGroup`, `role: .destructive`, sidebar
  `List` vibrancy, traffic lights, sheets.
- **Custom-styled pieces reference tokens** (everything in §2). They get dark for
  free once tokenized.
- **Materials:** keep `.regularMaterial`/vibrancy on the sidebar and popovers;
  it darkens automatically. The `sidebar` token is the ivory/ink overlay tint
  *on top of* that material.

---

## 6. Avatars — unchanged

Colorful initial-keyed gradients stay **exactly** as in light (they read well on
dark). White initials stay white. The only adaptive part — the separator ring
between stacked avatars and the `+N` badge ring — already uses the `card` token,
so it tracks the surface automatically. Do not tint avatars for dark.

---

## 7. Motion & accessibility

- Motion is unchanged and still reserved for the live state only: RECORDING
  halo (~2s), header dot pulse (~1.6s), amber warning dot (~1.7s), composer
  caret blink. Honor **Reduce Motion** (steady states).
- **Contrast:** the dark values target WCAG AA — `ink` ~16:1, `read` ~10:1,
  `ink2` ~7:1, `accent`/`alertText`/`amberValue` all clear AA on `content`.
  `accentFill`/`alertGrad` carry white labels at AA-large (≥3:1) — keep label
  weight ≥ 500 on them.
- Verify both appearances against the two reference HTML comps before shipping.

---

## 8. Quick diff (copy/paste)

```
// NEW TOKENS (light value = today's literal; only dark diverges)
accentFill   : #4E7D5C            →  #56906A     // button fills
read         : ink@54%            →  #F7F2E8@75% // transcript/notes body
elevatedFill : #FFFFFF            →  #1A170F     // white-button fill

// SURFACES
content      : #FBFAF5            →  #100E09
card         : #FFFFFF            →  #1A170F
cardBorder   : rgba(26,22,14,.10) →  rgba(247,242,232,.12)
ink 1/2/3    : #1A1813 /.54/.34   →  #F7F2E8 /.58/.36
separator    : rgba(26,24,19,.11) →  rgba(247,242,232,.12)
chip / fill  : ink@.06 / .05      →  rgba(247,242,232,.07 / .06)

// SAGE  (split: text vs fill)
accent(text) : #4E7D5C            →  #86C295
accentTrack  : #5D9069→#43704F    →  #5E9A6F
recordIdle   : #5D9069→#43704F    →  #5F9D70→#3F6F4D

// ALERT RED
alert        : #C9402B            →  #E5604A
alertText    : #B23320            →  #F08A78
alertGrad    : #DB5740→#BE331E    →  #E5604A→#C73D27

// AMBER (flips polarity)
amberValue   : #7D540A            →  #F0C04A
amberKicker  : #996A12            →  #D9A53A
amberWash    : amber@.18          →  amber@.15

// RULE: native controls follow appearance; custom pieces use tokens; no view conditionals.
```
```
