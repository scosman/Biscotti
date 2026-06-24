---
status: complete
---

# Dark Mode — Functional Spec

This spec turns the approved Dark Mode design (see `project_overview.md`) into a
concrete, code-grounded contract. It is the authoritative **token map** and the
list of **reconciliations** where the shipped code diverges from the comps.

The design doc is the source of truth for **dark color values**. The **code** is
the source of truth for **everything else** — light values, structure, which
elements exist, and whether a surface is flat or gradient.

---

## 1. Scope & non-goals

**In scope**
- Make the existing semantic palette appearance-adaptive so the app renders
  correctly in dark mode, following the system appearance.
- Add a small number of new semantic tokens where dark needs to split a role the
  light system collapsed (`accentFill`, `read`, `elevatedFill`, and two optional
  splits below).
- Repoint the handful of call sites those splits require, plus a few hardcoded
  literals (`Color.white` button/field fills, two `.black` shadows).

**Out of scope / non-goals**
- **No feature, layout, spacing, type, radius, navigation, or behavior changes.**
- **No new backgrounds, highlights, borders, or shadows** where the code does not
  already have one. (Where the design comps describe an element the code doesn't
  render — e.g. a gradient backdrop — we do **not** add it.)
- **No changes to light-mode rendering.** Light must be byte-for-byte identical.
- No in-app light/dark toggle.
- Avatar identity colors (`Tokens.avatarPalette`) and EventKit calendar colors
  (`Color(hex:)`) are **not** touched — they read on both appearances.
- Increased-Contrast accessibility variants are **future work** (the mechanism
  leaves room for them; see architecture).

---

## 2. Hard guarantees (acceptance contract)

1. **Light is unchanged, byte-for-byte.** Every token's light value equals the
   exact literal it replaces (same sRGB components, same alpha). Introducing
   adaptivity is a pure refactor for light.
2. **No appearance conditionals in view code.** There are zero
   `if colorScheme == .dark` branches in any view, `ButtonStyle`, or modifier.
   Appearance is resolved entirely inside the palette layer.
3. **Single source of truth.** Each color is defined once (one entry carrying a
   light value and a dark value). SwiftUI (`Color`) and AppKit (`NSColor`)
   consumers read the same source — the current hand-synced `Color`/`NSColor`
   duplication is eliminated.
4. **Follows the system.** No forced `preferredColorScheme`; the app already sets
   none, so adapting the tokens is sufficient.
5. **Native controls are left alone** — segmented `Picker`, `Slider`, `Menu`,
   `DisclosureGroup`, `role: .destructive`, sheets, materials, traffic lights,
   dividers — they adapt automatically.

---

## 3. Token families — light (keep) → dark (port)

Notation: light values are the **current code literals** (do not edit). Dark
values are hex from the design. "Derived" means the token is currently expressed
as `base.opacity(x)`; under the new mechanism it becomes an explicit two-value
entry so the dark alpha can differ from light (the design bumps several).

`#F7F2E8` = the dark "ink" (warm off-white) used as the base for all dark
text/separator/chip/wash-on-neutral values.

### 3.1 Surfaces & ink (redefine in place — no call-site changes)

| Code token | Light (keep exact) | Dark (port) | Notes |
|---|---|---|---|
| `paper` / `Tokens.contentBackground` | `#FBFAF5` | `#100E09` | pane/content bg |
| `wall` | `#E4E1D8` (flat) | `#110F09` (flat) | window backdrop. **Code is flat**, design comp is a radial — keep flat, port the midpoint dark value. |
| `sidebarTint` | `rgba(250,249,244,.82)` | `rgba(20,18,13,.74)` = `#14120D@74%` | flat tint (code has no vibrancy layer under it — keep flat) |
| `cardFill` / `Tokens.cardFill` | `#FFFFFF` | `#1A170F` | this is the design's `card`. Becomes adaptive; all card surfaces get dark for free. |
| `cardStroke` (`Color`+`NSColor`) | `rgba(26,22,14,.10)` | `rgba(247,242,232,.12)` | card border |
| `ink` (`Color`+`NSColor`) | `#1A1813` | `#F7F2E8` | primary text |
| `inkSecondary` (`Color`+`NSColor`) | `#1A1813 @54%` | `#F7F2E8 @58%` | derived → explicit (alpha bumps 54→58) |
| `inkTertiary` (`Color`+`NSColor`) | `#1A1813 @34%` | `#F7F2E8 @36%` | derived → explicit |
| `hairline` | `#1A1813 @11%` | `#F7F2E8 @12%` | separator; derived → explicit |
| `neutralChip` | `#1A1813 @6%` | `#F7F2E8 @7%` | derived → explicit |

### 3.2 Sage / accent

| Code token | Light (keep) | Dark | Notes |
|---|---|---|---|
| `sage` (`Color`+`NSColor`) / `Tokens.liveGreen` | `#4E7D5C` | `#86C295` | the **text/icon/link/timestamp** accent (design `accent`). Brightened in dark. |
| **`accentFill`** *(NEW)* | `#4E7D5C` (= sage) | `#56906A` | **button fills** under a white label. Light = sage (no change); dark = deeper sage for white-label contrast. |
| **`accentTrack`** *(NEW, optional — see §6)* | `#4E7D5C` (= sage, flat) | `#5E9A6F` | custom **progress-bar** fills. Code is flat sage (comp is a gradient) — keep flat. |
| `accentWashSoft` / `Tokens.speakerChipBackground` | `sage @8%` | `#86C295 @12%` | derived → explicit (dark base brightens + alpha bumps) |
| `accentWashStrong` (`Color`+`NSColor`) | `sage @14%` | `#86C295 @16%` | selection wash; derived → explicit |
| `softSageFill` | `sage @12%` | `#86C295 @14%` | "Add note" / soft button wash |
| `findHighlightFocused` (`Color`+`NSColor`) | `sage @35%` | `#86C295 @35%` | find-match; keep alpha |

### 3.3 Alert red

The codebase ships **one** canonical red `signalRed` `#B23320`, used for marks
**and** text. The design splits dark into a mark red and a (lighter) text red, but
its **light** split values (`alert #C9402B`) do **not** match the shipped single
red. Per "code wins + zero light change," **both** stay `#B23320` in light; only
dark diverges (exactly the `accentFill` pattern).

| Code token | Light (keep) | Dark | Notes |
|---|---|---|---|
| `signalRed` (`Color`+`NSColor`?) | `#B23320` | `#E5604A` | **marks**: dots, icons, stop-square, fills, borders. (design `alert`) |
| **`signalRedText`** *(NEW, optional — see §6)* | `#B23320` (= signalRed) | `#F08A78` | **standalone red text** labels (design `alertText`). Lighter for AA on dark. |
| `errorBackground` (`Tokens`) | `signalRed @15%` | `#E5604A @15%` | error banner wash. Auto-correct once signalRed is adaptive (design `alertWash` ≈ .13; keep code's .15). |
| `recordingTintSoft` | `signalRed @8%` | `#E5604A @8%` | sidebar / auto-stop wash; auto via adaptive signalRed |
| `recordingTintStrong` | `signalRed @12%` | `#E5604A @12%` | *(currently unused; keep adaptive)* |
| `recordingOutline` | `signalRed @32%` | `#E5604A @36%` | Stop/REC button & card ring (design `alertBorder` .36). Derived → explicit to hit .36. |
| `recordingOutlineStrong` | `signalRed @20%` | `#E5604A @20%` | *(unused; keep adaptive)* |
| `recordingHoverFill` | `signalRed @5%` | `#E5604A @5%` | button hover; auto via adaptive signalRed |

### 3.4 Amber / warning

The codebase ships **one** canonical `warningOchre` `#C6891E` (icons + dot) and
one `warningChipText` (= warningOchre) for both kicker and value text. The design
splits amber into kicker/value/wash/dot with **darker** light text values
(`#996A12`, `#7D540A`) than the shipped `#C6891E`. Per "code wins," **light stays
`#C6891E`** everywhere; dark ports the design's bright amber. We do **not** split
kicker vs value (see §6) — one bright amber text value reads well for both.

| Code token | Light (keep) | Dark | Notes |
|---|---|---|---|
| `warningOchre` (`Color`+`NSColor` mirror? Color only) | `#C6891E` | `#E8A13A` | warning **icons** (triangles) + the pulsing **dot** (design `amberDot`, reads in both) |
| `warningChipText` / `Tokens.warningChipText` | `#C6891E` (= ochre) | `#F0C04A` | amber **text**: time-chip kicker + value, "Requires …" labels. Redefine to its own dark value (no longer `= warningOchre`). |
| `warningBackground` / `warningChipFill` | `ochre @15%` | `#E8A13A @15%` | chip/banner **wash** (design `amberWash` .15). Auto via adaptive warningOchre; keep code's .15 (not the comp's .18). |

### 3.5 New surface/elevation tokens

| Code token | Light (keep) | Dark | Used by |
|---|---|---|---|
| **`elevatedFill`** *(NEW)* | `#FFFFFF` (= white) | `#1A170F` (= card) | the white-fill **buttons/fields**: Stop&Save / REC pill chrome (`LightAlertButtonStyle`), focused title field. Identical value to `card` today but semantically a control fill. |
| **`cardShadow`** *(NEW)* | `black @5%` | `black @40%` | `HomeCardModifier` shadow. Adaptive opacity only; radius/offset unchanged. |
| **`controlShadow`** *(NEW)* | `black @6%` | `black @40%` | `LightAlertButtonStyle` shadow. Separate token to keep light's 6% exact. |

> Shadows "recede" on dark (design §3). Tokenizing is low-stakes — black@5% on a
> near-black surface is nearly invisible regardless — but we tokenize for fidelity
> and to keep light byte-exact (5% vs 6% can't be collapsed).

### 3.6 Design tokens deliberately NOT created (code moved beyond the comps)

These appear in the design's token table but have **no flat-color home in the
code** (the code renders flat where the comp uses a gradient, or the element does
not exist). Per "code wins," we do not introduce them:

- `windowWall` **radial gradient** — code uses flat `wall`. Port flat only.
- `cardTop` / raised **card gradient** (`#FFFDFB → … `) — code cards are flat
  `cardFill`. No gradient cards exist.
- `recordIdle` **gradient** + `recordRing` — the idle Record button is a **flat**
  `accentFill` (no sage gradient, no sage ring in code; the in-pane ripple ring is
  **red**, handled by `signalRed`).
- `alertGrad` **gradient** — the REC pill / Stop&Save are white-fill + red text
  (`LightAlertButtonStyle`), not a red-gradient pill.
- `accentTrack` **gradient** — code progress fills are flat; we add a *flat*
  `accentTrack` (§3.2) not the gradient. The audio `Slider` keeps the bright
  `sage` tint per design ("its tint is accent(text-bright)").
- `fill` / `hover` neutral soft-fill tokens — the audit found **no** neutral
  `black.opacity(.04–.06)` hover/fill literals in view code (the only neutral
  blacks are the two card shadows; the only hover is the red `recordingHoverFill`).
  Nothing to repoint, so these tokens aren't needed. (Trivial to add later.)
- `windowHairline` — window/section dividers are native `Divider()`s that adapt
  automatically.

If any of these elements is later added to the code, the matching token can be
added then. We are not pre-building tokens for comps the code doesn't use.

---

## 4. Call-site repoints (the only view-code edits)

Everything else is a token **redefinition** (§3) with no call-site change. These
sites change which token they reference. None changes light pixels (each new
token's light value equals what's there today).

**`accentFill` (solid sage button fills → deeper dark sage):**
- `DesignSystem/JoinRecordButtonStyle.swift:19` — `.fill(Color.sage)` → `accentFill`
- `OnboardingUI/OnboardingPrimaryButtonStyle.swift:18` — `.fill(Color.sage)` → `accentFill`
- `AppShellUI/AppShellView.swift:99` — `ToolbarRecordButtonStyle(fill: .sage)` → `fill: .accentFill`
- `OnboardingUI/GrantedTag.swift:18` — `Circle().fill(Color.sage)` → `accentFill`
- *Leave* `SettingsUI/AlertsHelpSheet.swift:43` `.tint(.sage)` on a `.borderedProminent`
  button — native control; macOS suppresses custom tint there anyway.
- *Leave* `DesignSystem/RecordButton.swift:22` 10pt sage indicator dot — no white
  label; reads better at the brighter `sage` value.

**`elevatedFill` (white control fills):**
- `DesignSystem/LightAlertButtonStyle.swift:20` — `Tokens.cardFill` → `elevatedFill`
- `DesignSystem/EditableMeetingTitle.swift:117` — `Color.white` → `elevatedFill`
  (focused title field; dark = card surface lift, matching light's white lift)

**`read` (long-form body):**
- `MeetingDetailUI/TranscriptListView.swift:196` — transcript utterance text
  `.inkSecondary` → `.read`. (Speaker name stays its palette color; timestamp
  stays `.inkTertiary`. Notes body is already `.ink` — **stays `.ink`**, contrary
  to the comp's "notes body = label2," because the code already uses full ink.)

**`signalRedText` (standalone red text — optional, §6):**
- `RecordingUI/RecordingView.swift:217` — "RECORDING" label
- `RecordingUI/AutoStopCountdownCard.swift:46` — countdown seconds text
- `DesignSystem/EventPickerSheet.swift:125` — "Remove association"
- `ModelManagementUI/ManageModelsSheet.swift:281` — download-failed message
- `OnboardingUI/ModelDownloadCard.swift:208` — download-failed message
- *Leave* `LightAlertButtonStyle.swift:17` (single `foregroundStyle` tints the
  Stop-square **and** the label together — keep `signalRed`; `#E5604A` reads fine
  on the elevated card). *Leave* `Banner.swift:37` (mark icon).

**`accentTrack` (custom progress bars — optional, §6):**
- `OnboardingUI/ProgressHeader.swift:36`
- `OnboardingUI/ModelDownloadCard.swift:152` and `:266`
- *Leave* `DesignSystem/AudioTransport.swift:88` `Slider.tint(.sage)` (design keeps
  the slider tint at the bright accent).

**Shadows (tokenize):**
- `DesignSystem/HomeCardModifier.swift:14` — `.black.opacity(0.05)` → `Color.cardShadow`
- `DesignSystem/LightAlertButtonStyle.swift:28` — `.black.opacity(0.06)` → `Color.controlShadow`

---

## 5. Hardcoded sites that intentionally stay

- **White labels on colored fills** (`JoinRecordButtonStyle:14,56`,
  `OnboardingPrimaryButtonStyle:13`, `GrantedTag:23`, `ToolbarRecordButtonStyle:56`)
  — white text/icon on sage/red fill is correct in both modes. Keep.
- **White sheen gradients** over filled buttons (`JoinRecordButtonStyle:24-25`,
  `OnboardingPrimaryButtonStyle:22-23`) — a top highlight on the fill; keep.
- **Avatars** (`Avatar.swift` palette gradient, white rings `:48,64,187,217,227`,
  white initials `:53,57,221`) — unchanged per design §6; the separator/`+N` rings
  already use the `card` token and track the surface automatically.
- **`.ultraThinMaterial`** (`MeetingDetailView.swift:1064`) — adapts automatically;
  behind a `macOS 26` `.glassEffect` guard. Leave.
- **`Color(hex:)`** calendar colors and **`Tokens.avatarPalette`** — data/identity
  colors; not migrated.
- **Native controls** — segmented `Picker`, `Slider` rail, `Menu`/popovers,
  `DisclosureGroup`, `.destructive`, `Divider`, sheets. Leave.

---

## 6. Open judgment calls (decided here; flagged for review)

Three of the design's splits are subtle and slightly grow the codebase's
deliberately minimal "one red / one amber / one sage" palette. I've **decided to
include the high-value ones** and **simplify the lowest-value ones**, but these
are easy to flip during spec review:

1. **`signalRedText` (red text split) — INCLUDED.** Standalone red text at the
   mark red `#E5604A` is only ~4.5:1 on dark (borderline AA); the design's lighter
   `#F08A78` (~7:1) is a real legibility win for error/recording text. Cost: 1
   token + 5 repoints. *Alternative:* drop it and let red text use `signalRed`
   `#E5604A`.
2. **`accentTrack` (progress-bar split) — INCLUDED.** The design wants progress
   fills a touch less bright than text sage (`#5E9A6F` vs `#86C295`). Cost: 1
   token + 3 repoints. *Alternative:* drop it and let progress bars use `sage`
   `#86C295`.
3. **Amber kicker vs value split — SIMPLIFIED OUT.** The design splits amber text
   into kicker `#D9A53A` and value `#F0C04A`; the code uses one `warningChipText`
   for both. We keep one token at the brighter `#F0C04A` (more legible; the only
   effect is the small "LEFT/OVER" kicker being a hair brighter than the comp).
   *Alternative:* split into two tokens to match the comp exactly.

If the reviewer prefers maximum minimalism, (1) and (2) collapse into `signalRed`
and `sage` with no other change.

---

## 7. Per-surface behavior (reconciled with code)

All "palette swap" — listed only where there's a nuance beyond §3/§4.

- **Home:** pure token swap (greeting serif, mono kickers/timestamps, stat chips,
  `accentWashSoft` hero row, avatars). Nothing special.
- **Meeting Detail:** transcript body → `read` (§4); speaker names keep palette
  colors; timestamps `inkTertiary`; segmented control, Slider, `.destructive`
  Delete, "…" Menu/popovers all native. Source pill / soft buttons use
  `neutralChip`/`accentWashSoft` + `inkSecondary` (already token-driven).
- **Active Recording:** RECORDING dot `signalRed` (mark) + label `signalRedText`;
  Stop&Save / REC pill = `elevatedFill` fill + `recordingOutline` border + red
  content; Elapsed chip = `neutralChip`; Left≤5:00 chip = `warningChipFill` +
  `warningChipText` + `warningOchre` dot; note composer = `softSageFill` +
  `sage` timestamps. (All via §3/§4 — no structural change.)
- **Upcoming Event / Onboarding:** token swap; progress bars → `accentTrack`
  (§4); permission cards `accentWashSoft` + `sage` checks; CTA buttons
  `accentFill`; destructive items `signalRed`/`signalRedText`.

---

## 8. Accessibility & motion

- **Contrast (dark):** targets from design — `ink` ~16:1, `read` ~10:1,
  `inkSecondary` ~7:1; `sage`/`signalRedText`/`warningChipText` clear AA on
  `content`; `accentFill` carries white labels at AA-large (keep label weight
  ≥ 500, already the case in the button styles).
- **Motion is unchanged** (recording halo, header dot pulse, amber dot, caret
  blink) and still honors Reduce Motion exactly as today — no motion edits.
- Increased-Contrast appearance variants are out of scope; the dynamic-color
  helper is structured so they can be added later without touching call sites.

---

## 9. Verification / acceptance criteria

1. **Light unchanged:** existing unit/snapshot tests pass; a spot diff of key
   screens in light shows no pixel change. (The token literals are provably equal;
   verify the mechanism preserves sRGB exactly — see architecture.)
2. **Dark renders correctly:** Home, Meeting Detail (transcript + notes), Active
   Recording (Stop&Save, REC pill, time chips incl. amber ≤5:00, RECORDING badge),
   Upcoming, Onboarding, Settings, model-management sheets, banners (error +
   warning), and the menu-bar surfaces all show no white-on-light / light-on-light
   defects in dark.
3. **No conditionals:** grep confirms zero `colorScheme ==` / `@Environment(\.colorScheme)`
   in view code; the only appearance switch lives in the palette helper.
4. **Single source:** `Color` and `NSColor` tokens derive from one definition; the
   markdown editor (AppKit) adapts.
5. Manual on-hardware check toggling System Settings → Appearance Light/Dark with
   the app open (live switch updates without relaunch).
