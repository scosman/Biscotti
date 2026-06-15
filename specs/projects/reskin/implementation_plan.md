---
status: complete
---

# Implementation Plan — Reskin

Ordered, dependency-first. Each phase is one coherent, reviewable unit. Details
live in `functional_spec.md`, `ui_design.md`, `architecture.md` — this is the
checklist, not a restatement.

## Phases

- [x] **Phase 1 — Theming foundation** (`DesignSystem` + app glue). The base
  everything else consumes; do first.
  - Re-value `Tokens.swift` to F · Sage colors; `liveGreen` → `sage`;
    `recordingRed` stays `.red`; `avatarPalette` unchanged.
  - New files: `Color+Theme.swift` (Color + `ShapeStyle` sugar),
    `Font+Theme.swift` (serif/mono helpers + semantic ramp tokens),
    `FontRegistration.swift`, `Modifiers.swift` (`.kicker()`).
  - Move the minimal TTFs (+ OFL/LICENSE) into
    `DesignSystem/Resources/Fonts/`; delete the rest + the empty
    `App/Resources/{JetBrainsMono,Newsreader}`; add `resources:` to the
    `DesignSystem` target in `Package.swift`.
  - App: `AccentColor` asset = sage; `.tint(.sage)` at window root;
    `FontRegistration.ensure()` at launch.
  - Test: font-registration test asserting each pinned PostScript name resolves
    (`architecture.md` §6). Verify Newsreader's exact Display PostScript name.
  - Gate: `make ci` green; `make build-app` builds.

- [x] **Phase 2 — DesignSystem components re-tokenized.** Re-skin every shared
  component (`architecture.md` §5 "DesignSystem"): Avatar/AvatarCluster,
  StatChip, UpcomingEventRow, MeetingPlatformChip, HomeCardModifier/InsetDivider,
  JoinRecordButtonStyle, TranscriptSegmentRow, StatusRow (success→sage), Banner,
  AudioTransport, CalendarContextBlock, RecordButton. Verify each `#Preview`
  reads correctly.

- [x] **Phase 3 — Home + App shell** (primary surfaces + both additive
  elements). `HomeView` (serif greeting, mono numbers/kickers, sage links/
  countdowns, footer brand mark) and `AppShellView` (**new sidebar brand
  lockup**, **idle Record → sage** / active stays red, sage selection + glyphs,
  mono kicker, the window-wall/sidebar-tint seam with flat fallback). Highest
  visual surface area; review on a real `build-app` run.

- [x] **Phase 4 — Remaining screens.** Mechanical token/family swaps per
  `architecture.md` §5: `MeetingListView` (+ ContentUnavailableView serif title),
  `MeetingDetailView`/`EventPreviewView`, `RecordingView` (counter → mono, else
  unchanged), Onboarding (serif headline, success→sage), `SettingsView`. Menu
  bar deliberately untouched. Final pass: grep UI modules for stray
  systemBlue / cool-neutral / raw `Font.system` (acceptance §8).

## Notes

- Phase 1 carries the only real risk (font name resolution, resource bundle);
  the registration test de-risks it. Phases 2–4 are largely mechanical once the
  token vocabulary exists.
- No new test infra (no snapshot tests). SwiftUI previews + a `build-app` run are
  the visual checks. Manual-test gate is unaffected (UI + DesignSystem only).
