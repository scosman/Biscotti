---
status: complete
---

# UI Design: Onboarding Redesign

Visual realization of the flow in `functional_spec.md`. The design-agent brief
is the *intent*; this document binds that intent to Biscotti's **existing**
`DesignSystem` tokens, fonts, and components. Where the brief's literal values
conflict with the codebase, **the codebase wins** (noted inline). All of this
lives in `Packages/BiscottiKit/Sources/OnboardingUI` (+ a few small additions to
`DesignSystem` for genuinely reusable pieces).

---

## 1 · Principles

- **Light appearance only.** Calm, centered, roomy. One sage accent, one serif
  display moment per screen (the title), mono for the kicker/numerals, SF Pro
  for everything else — the app's existing three-font rule.
- **Reuse before inventing.** Prefer existing components/modifiers
  (`.homeCard()`, `InsetDivider`, `.kicker()`, `JoinRecordButtonStyle`,
  `Banner`, `FixPermissionsAlert`) over hand-rolled gradients/shadows from the
  brief.
- **Resizable-window-safe.** The window is not fixed at 960×680 (see
  functional_spec §8); layout centers within max-width caps and must stay
  legible from the min window size (640×400) up.

---

## 2 · Token & font mapping (brief `Pal`/fonts → project)

| Brief | Use | Project token |
|---|---|---|
| `Pal.accent` `#4E7D5C` | accent, fills | `Color.sage` (identical hex) |
| `Pal.accentWash` (sage 10%) | permission icon tile bg | `Color.accentWashSoft` (sage 8%) |
| `Pal.label` `#1A1813` | primary ink | `Color.ink` |
| `Pal.label2` (ink 56%) | lead/secondary copy | `Color.inkSecondary` (ink 54%) |
| `Pal.label3` (ink 36%) | kicker/tertiary/skip | `Color.inkTertiary` (ink 34%) |
| `Pal.content` `#FBFAF5` | window bg | `Color.paper` |
| `Pal.card` white | card fill | `Tokens.cardFill` |
| `Pal.cardBdr` | card border | `Color.cardStroke` (0.5pt) |
| `Pal.sep` (ink 11%) | row divider | `Color.hairline` |
| `Pal.track` (ink 10%) | progress track | `Color.hairline` |

**Fonts** (the brief's "Newsreader"/"IBM Plex Mono" are *roles*, not literal
families — the project bundles different files):

| Role | Project font | Onboarding use |
|---|---|---|
| Serif display | `Font.biscottiSerif(size)` (**Newsreader Display**, wt 500) | the step **title** only |
| Mono | `Font.biscottiMono(size, weight:)` (**JetBrains Mono**) | kicker, "GRANTED", download %/size numerals |
| System | `.system(...)` (SF Pro) | lead copy, buttons, row name/why, Skip, footer tagline |

The kicker uses the existing **`.kicker()`** modifier (JetBrains Mono 10.5pt
medium, uppercase, tracking +1.47) — *not* the brief's 11pt/1.8. The card uses
**`.homeCard()`** (radius 12) — *not* the brief's radius 14. These keep
onboarding visually identical to Home/Meeting Detail.

---

## 3 · Window & scaffold

Onboarding is the full-window content of `Window(id:"main")` while
`route == .onboarding` (unchanged). Background `Color.paper`, full-bleed
(`.ignoresSafeArea`). The title bar is already hidden; traffic lights float
top-left.

**`OnboardingScaffold`** (new, OnboardingUI) — every screen uses one three-region
vertical layout:

```
VStack(spacing: 0) {
    ProgressHeader(step:)          // top; .padding(.top, ~28) clears float lights
    Spacer(minLength: 24)
    <screen content>               // centered; .multilineTextAlignment(.center)
        .frame(maxWidth: 520)      // prose cap; cards set their own width
    Spacer(minLength: 24)
    BrandFooter()                  // bottom — extracted from Home (§5)
}
.frame(maxWidth: .infinity, maxHeight: .infinity)
.padding(.horizontal, 40)         // adapts; content is centered + capped anyway
.padding(.bottom, 28)
.background(Color.paper.ignoresSafeArea())
```

- Two `Spacer`s vertically center the content; header pins top, footer pins
  bottom. (The brief's exact 70/34/24 paddings are relaxed because the window
  is resizable — centering + max-width caps carry the "roomy" feel.)
- Content max-width **520** for prose; lead paragraphs cap tighter (~440–460).

---

## 4 · Progress header

**`ProgressHeader`** (new) — a thin sage bar + mono kicker, centered. Replaces
the dot indicator.

- Track: `Capsule().fill(Color.hairline)`, **240 × 3**.
- Fill: `Capsule().fill(Color.sage)`, width `240 * (position+1)/5`, where
  `position` is the screen's fixed index 0–4 (Welcome…Done; Choose calendars =
  2). See functional_spec §2 — the bar jumps past skipped Choose-calendars.
- Kicker below (`spacing 9`): `Text(kicker).kicker().foregroundStyle(.inkSecondary)`
  — text per functional_spec §1 (WELCOME / PERMISSIONS / CALENDARS / AI MODELS /
  FINISH).
- Centered: `.frame(maxWidth: .infinity)`.
- The single progress affordance — no dots, no "X of N", no Back button.

---

## 5 · Footer lockup

**Reuse the existing Home footer.** `HomeView.swift` already has a private
`HomeFooter` brand lockup (sage `lock.shield.fill` 16pt; "Biscotti" SF Pro 13
semibold, tracking −0.1, `.ink`; tagline "Total recall, total privacy." SF Pro
12 `.inkTertiary`; vertical stack, `spacing 3`). The onboarding footer is the
**same** lockup.

- **Extract** `HomeFooter` → a public `BrandFooter` (or similarly named) view in
  **`DesignSystem`**, *without* its Home-specific `.padding(.top, 30)`.
- `HomeUI` replaces its private `HomeFooter` with `BrandFooter` (keeping the
  `.padding(.top, 30)` at the Home call site so Home is visually unchanged).
- The onboarding `OnboardingScaffold` pins `BrandFooter` at the bottom (the
  bottom `Spacer` provides separation; no baked top padding, no divider).

This resolves the wordmark question — the shared lockup is SF Pro semibold, as
it ships today. Not interactive.

---

## 6 · Shared controls

**Primary CTA — `OnboardingPrimaryButtonStyle`** (new, OnboardingUI). The roomy
sage button for the footer CTA (Continue / Get Started) and the in-content
Download Now. Same visual idiom as `JoinRecordButtonStyle` (sage fill, white
label, subtle top highlight, pressed-dim) at onboarding scale:

- Height **40**, radius **9**, fill `Color.sage`, label SF Pro **14.5 semibold**
  white, optional leading SF Symbol (15pt medium), top-highlight overlay,
  `opacity 0.7` when pressed, `0.4` when disabled.

**Grant pill** (per permission row) — **reuse `JoinRecordButtonStyle`** (sage,
height 32, radius 8, white 13.5 semibold). Matches the brief's 30/r8 pill closely
without a new style. Label "Grant".

**Skip link** — plain text button, SF Pro **13.5**, `Color.inkTertiary`, no
chrome. Label "Skip". (The Grant-access and Download footers show this until
their gate is met; see §7.)

**Granted tag** — non-interactive: a **15pt** sage-filled `Circle` with a white
`checkmark` (SF Symbol ~9pt bold), then `Text("GRANTED").kicker()` in
`Color.sage`.

**Denial guidance** (mic, calendar `.denied`) — unchanged content, restyled
inline in the row: `exclamationmark.triangle.fill` (`.warningOchre`) + "Denied?"
+ a plain **Open System Settings** sage text button → `openSettings(for:)`.

---

## 7 · Per-screen layouts

### 7.1 Welcome
Title `Font.biscottiSerif(46)` "Welcome to Biscotti" (`Color.ink`). Lead SF Pro
16 `.inkSecondary`, maxWidth 460, ~16pt below. `OnboardingPrimaryButtonStyle`
"Continue" ~30pt below → advance. Footer: always Continue (no Skip on Welcome).

### 7.2 Grant access
Title `Font.biscottiSerif(34)` "Grant access". Lead SF Pro 16 `.inkSecondary`,
maxWidth 440. Then the **permission card** (`.homeCard()`, width 520) with four
rows separated by `InsetDivider(leadingInset: 48)` (inset under the text, past
the icon tile). Footer (in scaffold, below card ~24pt): **Skip** until all four
granted, then **`OnboardingPrimaryButtonStyle` Continue** (functional_spec §3).

**`PermissionRow`** (new) — `HStack(spacing: 14)`, padding `.vertical 15 /
.horizontal 16`:

| Element | Spec |
|---|---|
| Icon tile | 34×34 `RoundedRectangle(cornerRadius: 9).fill(Color.accentWashSoft)`, SF Symbol centered 18pt medium `.sage` |
| Name | SF Pro 14.5 semibold `.ink` |
| Why | SF Pro 12.5 `.inkSecondary`, 2pt under name |
| Trailing | state-dependent (below) |

Rows, symbols, copy (functional_spec §10):

| Row | SF Symbol | Name / Why |
|---|---|---|
| Microphone | `mic.fill` | "Microphone" / "Record your voice locally to transcribe your meetings." |
| System Audio | `speaker.wave.2.fill` | "System Audio" / "Capture the other side of your call." |
| Calendar | `calendar` | "Calendar" / "Join meetings and connect event data" |
| Notifications | `bell.fill` | "Notifications" / "Alerts when meetings are starting" |

Trailing view by state (each row independent; row does **not** reflow on change):

- **Microphone:** ungranted → Grant pill; `.authorized` → Granted tag;
  `.denied` → Grant pill **and** denial guidance beneath the row's why text.
- **System Audio** (preserve `SystemAudioPermissionState` machine):
  - `.notRequested` → Grant pill ("Grant").
  - validating (`isValidatingSystemAudio`) → small `ProgressView` + "Validating…"
    (mono 11 `.inkSecondary`).
  - `.requestedNotVerified` → "Not approved" (mono 11 `.inkSecondary`) + a small
    **Retry** sage pill (`JoinRecordButtonStyle`) + a plain **Fix** sage text
    link → `showFixPermissionsAlert = true`.
  - `.approved` → Granted tag.
  - The `.fixPermissionsAlert(...)` modifier (reused, same title/body) stays
    attached to this screen.
- **Calendar:** ungranted → Grant pill; `.authorized` → Granted tag; `.denied`
  → Grant pill + denial guidance ("Open System Settings").
- **Notifications:** ungranted → Grant pill; granted → Granted tag.

On screen entry, `syncLivePermissionState()` runs for **all four** rows so
already-granted permissions show the Granted tag immediately.

### 7.3 Choose calendars
Title `Font.biscottiSerif(34)` "Choose calendars". Lead SF Pro 16
`.inkSecondary`. A `.homeCard()` (width 520, maxHeight-capped `ScrollView`)
containing the grouped calendars:

- Per source group: a `Text(group.sourceTitle).kicker().foregroundStyle(.inkSecondary)`
  header, then a `Toggle` per calendar — label = color dot (10pt
  `Color(hex: cal.colorHex)`) + `Text(cal.title)` (SF Pro 14.5) — `.tint(.sage)`,
  bound via the existing `calendarBinding`.
- Footer: **Continue** (always; this screen is never gated).

### 7.4 Download Local AI Models
Title `Font.biscottiSerif(34)` "Download Local AI Models". Lead SF Pro 16
`.inkSecondary`, maxWidth 430; render "~1.5 GB" inline in `Font.biscottiMono`.
Content state machine (preserve functional_spec §5):

- **Insufficient disk:** `Banner("Not enough disk space. Need ~2000 MB.",
  style: .warning)`. No Download control; footer = Skip only.
- **Idle:** `OnboardingPrimaryButtonStyle` "Download Now" with leading
  `arrow.down.circle` → `startDownload()`.
- **Downloading:** a **240×3 sage `ProgressView`-style bar** (reuse the
  ProgressHeader bar metrics/colors; indeterminate is fine if no fraction) +
  a mono caption from `downloadStatus` (`Font.biscottiMono(11)` `.inkSecondary`).
  Footer remains **Skip**.
- **Failure:** `downloadStatus` = "Download failed. You can retry or skip." shown
  as the caption (or `Banner(..., style: .error)`); Download Now returns for
  retry; Skip remains.
- **Complete:** Granted-tag-style "Models ready"; footer becomes **Continue**.

### 7.5 You're all set
Title `Font.biscottiSerif(50)` "You're all set" (the large terminal serif
moment). Lead SF Pro 16 `.inkSecondary`, ~18pt below.
`OnboardingPrimaryButtonStyle` "Get Started" ~30pt below → `completeOnboarding()`.

> Optional flourish (brief): a **64 × 3** sage `Capsule` centered ~14pt under the
> title. Off by default — include only if it reads well on hardware and doesn't
> echo the progress bar.

---

## 8 · Motion

- **Step transitions:** content block cross-fades (`.opacity`) with a **+8pt**
  vertical offset settling to 0, `.easeInOut(0.28)`. Header bar fill animates its
  width over the same change; footer is static. (The VM already animates
  `step` changes with `withAnimation(.easeInOut(0.28))` in `advance()`.)
- **Progress fill:** `.easeInOut(0.25)` on width, keyed on the step.
- **Grant → Granted:** `.spring(response: 0.32, dampingFraction: 0.8)` swap of
  the row's trailing view; the row does **not** reflow (icon/name/why fixed).
- **Reduced Motion** (`@Environment(\.accessibilityReduceMotion)`): drop the
  offset and springs; keep instant opacity swaps. Nothing loops.
- Idle states are **static** — no pulsing (pulse/red is reserved for live
  recording elsewhere).

---

## 9 · New vs reused components

**New (OnboardingUI unless noted):**
- `OnboardingScaffold` (§3) · `ProgressHeader` (§4) ·
  `OnboardingPrimaryButtonStyle` (§6) · `PermissionRow` + the permission card
  assembly (§7.2) · the Granted tag (small view, may live in DesignSystem if
  reused).

**Extracted to shared `DesignSystem` (then reused by Home + onboarding):**
- `BrandFooter` (§5) — promoted from Home's private `HomeFooter`.

**Reused verbatim:**
- `.homeCard()`, `InsetDivider`, `.kicker()`, `JoinRecordButtonStyle`, `Banner`,
  `FixPermissionsAlert` / `.fixPermissionsAlert`, all `Color`/`Font`/`Tokens`.
- The `OnboardingViewModel` (minus the removed `.launchAtLogin` step) — view
  layer only is reskinned; VM behavior is preserved.

---

## 10 · Open visual choices (resolve in review)

1. **Serif title sizes** (Welcome 46 / middle 34 / Done 50) are starting points
   tuned for the default ~1000×640 window; final tuning on hardware.

**Resolved:** footer lockup = reuse extracted `BrandFooter` (SF Pro semibold,
§5). Done-screen underline flourish = **off** (§7.5).
