---
status: complete
---

# Functional Spec — Reskin ("F · Sage + Pressroom type")

## 0. Nature of this project

This is a **visual re-skin**. It changes the app's *paint* — colors, fonts,
surfaces — and nothing else. Concretely, the following are **preserved
verbatim** on every screen:

- Layout, composition, spacing, sizing, alignment, the type *scale*
  (sizes/weights per element).
- Navigation, routing, screen inventory, and all interactions
  (chevron-vs-button rules, soon-row hero treatment, avatar stacking, search,
  toolbar behavior, keyboard shortcuts).
- All copy/strings, view models, business logic, and data flow.

The design agent's "Rev F → F · Sage" guide is the source of truth for new token
*values*. The design agent is a *design* source: nothing it proposes is a UX or
behavior change. Where the agent's guide describes a layout/structure that
doesn't exist in the current app (e.g. a sidebar wordmark, a gradient "record
pill"), we follow the **current app's** structure, not the mockup — except for
the two explicitly-approved additive elements in §1.

## 1. The only intentional additions (everything else is recolor/retype)

Two small **additive** design elements were explicitly approved. They are the
sole places new UI appears; they introduce no new behavior.

1. **Sidebar brand lockup (new).** Add a brand lockup at the top of the sidebar:
   the `lock.shield.fill` SF Symbol tinted **sage**, left of the **"Biscotti"**
   wordmark. The wordmark stays **SF Pro** (the wordmark was excluded from the
   serif; see §3). For consistency, the same sage `lock.shield.fill` mark is
   added to the existing Home **footer** lockup (which currently shows the
   "Biscotti" text with no mark).

2. **Idle "Record" toolbar button → sage.** The idle/ready toolbar Record button
   adopts the sage accent (icon + tint). The **active** "Recording… {counter}"
   state stays **red** (see §4).

## 2. Goal & success definition

Move the entire app from the current Pro palette (cool near-white, systemBlue
accent, all-SF-Pro type, red record control) to the **F · Sage** identity —
warm ivory paper, warm near-black ink, **sage-green** primary, a restrained
**Newsreader** serif, and **JetBrains Mono** for numbers/kickers — by routing
the whole app through a single, reusable, native-SwiftUI design language in the
`DesignSystem` module.

**Done when:**
- Every screen renders in the F · Sage identity (full per-surface list in §5).
- The design language is centralized: screens consume named semantic tokens /
  reusable styles; no raw `systemBlue`/`Color.accentColor`-as-blue, cool-neutral
  literals, or ad-hoc system fonts remain at call sites where a token should
  apply (intentional reds for "live" excepted).
- `make ci` (lint + test + build) is green; `make build-app` builds.
- No behavior, layout, or copy changed (visual diff only).

## 3. Type system (the "Pressroom" rule)

Three families, each with a clear job. The type **scale** (every element's size
and weight) is inherited unchanged from the current app; only the **family**
changes per the rules below.

| Family | Role | Where |
|---|---|---|
| **SF Pro** (system) | Workhorse | Row titles, body, descriptions, participant names, search field, button labels, the "Biscotti" wordmark, all screen chrome not covered below. |
| **Newsreader** (serif) | Restrained editorial accent | **Only**: (a) the Home greeting ("Good morning, …"), (b) the Onboarding welcome headline ("Welcome to Biscotti"), (c) large empty-state headlines we fully control. Nowhere else. |
| **JetBrains Mono** (monospace, tabular) | Numbers & "of-record" labels | All timestamps, countdowns ("in 6m"), durations ("32m"), times ("9:00 AM"), counts ("5 meetings", "+N" badges), the recording elapsed counter, and **uppercase kicker labels** ("UPCOMING", "PAST MEETINGS", sidebar section labels). |

Notes:
- **Serif is deliberately rare.** Default to SF Pro; reach for Newsreader only
  at the three moments above. If a new serif candidate appears, ask before
  adding it.
- Mono uses **tabular figures** so countdowns/counters don't jitter (replaces
  today's ad-hoc `.monospacedDigit()` on SF Pro).
- The wordmark ("Biscotti", sidebar + footer) is **SF Pro**, not serif (per the
  approved scope). This intentionally diverges from the design agent's spec.
- The full type ramp (every element → family/size/weight/tracking) lives in
  `ui_design.md`.

## 4. Color system (sage replaces systemBlue; warm ivory replaces cool white)

- **Primary/accent = sage** (`#4E7D5C`), retiring systemBlue everywhere it was
  used "for time-sensitivity, not decoration": live countdowns, text links
  ("View in calendar", "See all"), selected sidebar nav tint + glyph, stat-chip
  calendar icon, the idle Record button, the Home hero button, accent washes.
- **Success/"live" green unifies into the same sage** (`#4E7D5C`) — the Meet/
  conference video icon and the "Next in" dot use sage; there is no separate
  success green anymore.
- **Surfaces go warm:** ivory paper content background, warm near-black ink,
  warm-tinted secondary/tertiary/separator/chip neutrals, white cards with a
  warm hairline. The window "wall" (behind the sidebar) and the sidebar material
  pick up the warm ivory treatment as far as native SwiftUI allows.
- **Avatar gradients stay colorful** (the existing 16-color initial-keyed
  palette is unchanged — not tinted sage).
- **Red is retained only for "live/recording"** (see below).

Full color values (hex/opacity) and the surface treatments live in
`ui_design.md`.

### Recording / record affordance (explicit)

Red is **not** retired for recording — only the *idle/ready* affordance goes
sage. Specifically:

| Surface | Treatment |
|---|---|
| **RecordingView** (full-screen active recording) | **Unchanged.** Red pulsing dot (the existing opacity "VCR LED"), elapsed counter (→ JetBrains Mono), red "Stop" button. The red here is the `recordingRed` token, which **stays red**. |
| **Toolbar — idle "Record"** | **→ sage** (icon + tint). "Ready to record" reads sage. |
| **Toolbar — active "Recording… {counter}"** | **Stays red** (`recordingRed`, `.borderedProminent`). No pulse (it has none today). Counter → JetBrains Mono. |
| **Home hero "Join & Record" / "Record"** | Sage (it's accent-driven via `JoinRecordButtonStyle`). |
| `recordingRed` token | **Stays red.** Only the idle/ready control adopts sage. |

Rationale: sage = "ready", red = "live". The universal "recording = red" cue is
preserved.

## 5. Per-surface change inventory

For each surface: what recolors/retypes. **Unless listed, layout/structure/copy
is untouched.** "Accent → sage" happens automatically once the app tint + tokens
are sage; it is listed where a call site currently hard-codes blue/accent.

- **DesignSystem components** (reused everywhere — the highest-leverage changes):
  `Tokens`, `Avatar`/`AvatarCluster` (palette unchanged; "+N" badge text →
  mono; ring neutrals warm), `StatChip` (value text → mono; calendar tint →
  sage; "next" dot → sage), `UpcomingEventRow` (time → mono; neutrals warm),
  `MeetingPlatformChip` (video icon → sage; chip fill → warm neutral),
  `HomeCardModifier`/`InsetDivider` (card stroke + hairline → warm),
  `JoinRecordButtonStyle` (fill → sage via accent), `TranscriptSegmentRow`
  (speaker chip → sage wash), `Banner`, `StatusRow`, `CalendarContextBlock`,
  `AudioTransport` (times → mono), `VersionPicker`, `RecordButton` (currently
  **unused** — re-skin its red dot to match the affordance rules, or leave;
  decided in `ui_design.md`).
- **Home** (`HomeView`): greeting → Newsreader; date line, countdowns, times,
  stat values, "+N", past-row meta, kickers → mono; ink/secondary/tertiary →
  warm; `Color.accentColor` link/countdown call sites → sage token; content
  background → ivory; footer lockup → add sage brand mark. Empty-state
  headlines ("No meetings coming up", "No recordings yet") → Newsreader.
- **App shell** (`AppShellView`): add sidebar brand lockup (§1); selected-nav
  tint/glyph + selection wash → sage; sidebar section kicker ("UPCOMING") →
  mono; idle Record → sage, active Recording stays red; sidebar material +
  window wall → warm; search field neutral → warm.
- **Meeting list** (`MeetingListView`): warm neutrals; any time/duration meta →
  mono; `ContentUnavailableView` empty states (see `ui_design.md` for whether
  the headline gets serif via the label closure).
- **Meeting detail / Event preview** (`MeetingDetailView`, `EventPreviewView`):
  warm neutrals; metadata times/dates → mono; section kickers → mono; accent
  wash (line 259) → sage; speaker chips → sage wash.
- **Recording** (`RecordingView`): elapsed counter → mono (tabular); everything
  else unchanged (red stays red).
- **Onboarding** (`OnboardingView`, `OnboardingStepViews`): welcome headline →
  Newsreader; warm neutrals; success/granted checkmarks **→ sage** (unified with
  the brand); body stays SF Pro.
- **Settings** (`SettingsView`): warm neutrals; SF Pro stays (utility surface);
  any numeric/version text → mono where it reads as data.
- **Menu bar** (`MenuBarContentView`, `MenuBarLabelView`): the system menu-bar
  dropdown uses `.menu`-style `MenuBarExtra`, so macOS renders its rows as native
  menu items. We **intentionally keep the native macOS menu look here** — it is
  the correct, good-citizen treatment for a status-bar menu, not a compromise.
  Custom fonts/colors are therefore not applied to the dropdown rows by design.
  The status-bar **label** (`MenuBarLabelView`) keeps its current treatment
  (icon + `.monospacedDigit()` elapsed text). Success of the reskin does **not**
  require restyling this surface.

## 6. Fonts — bundling & registration

- **Bundle** the minimal weights needed (no webfonts, no variable fonts, no
  italics unless used): JetBrains Mono (the weights the type ramp uses, e.g.
  Regular/Medium) and Newsreader **Display** optical size (the weight the
  greeting uses, e.g. Medium). Keep each family's OFL/LICENSE file with the
  bundled files.
- Fonts are bundled as **package resources** and registered at runtime so they
  work from every UI package and in SwiftUI previews (mechanism in
  `architecture.md`). They are **not** assumed present on the system.
- Exact file list + weights are pinned in `architecture.md` (§ fonts).

## 7. Out of scope / non-goals

- **No dark mode.** Single light theme only (the app is light-only).
- No layout/structure/navigation/copy changes; no new screens or features.
- No signing/notarization work (Project 9).
- The system menu-bar dropdown keeps the **native macOS menu look on purpose**
  (see §5) — it is deliberately not re-themed.
- No change to the avatar color palette or to recording/transcription behavior.

## 8. Acceptance criteria

1. **Identity applied:** every surface in §5 renders F · Sage; the two additive
   elements in §1 are present.
2. **Centralized:** new colors/fonts flow through `DesignSystem` semantic tokens
   + reusable styles. A grep of the UI modules finds no stray systemBlue / cool
   near-white / raw `Font.system` where a token should apply (intentional reds
   for "live" and the `.menu` menu bar excepted).
3. **No behavior/layout/copy diff:** the change is visual-only; previews and
   interactions behave identically.
4. **Green checks:** `make ci` passes (lint + test + build); `make build-app`
   builds. Fonts load (verified on a real run / preview).
5. **Manual-test gate unaffected:** changes are confined to UI + `DesignSystem`
   (not `Packages/Transcription` or `Packages/AudioCapture`), so the
   manual-test staleness gate is not triggered.
