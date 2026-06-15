---
status: complete
---

# Phase 1: Theming Foundation

## Overview

Build the DesignSystem theming foundation that all subsequent phases consume:
re-value `Tokens.swift` to F Sage colors, add semantic color/font extensions,
bundle the minimal font files as package resources, register them at runtime,
wire font registration + sage tint into the app, and write a font-registration
test. This phase carries the single riskiest piece (custom font PostScript name
resolution) and de-risks it with the registration test.

## Steps

1. **Create `DesignSystem/Resources/Fonts/` directory** and move the three
   needed TTFs + two license files from `App/Resources/`:
   - `JetBrainsMono-Regular.ttf`, `JetBrainsMono-Medium.ttf`, `OFL.txt`
   - `NewsreaderDisplay-Medium.ttf`, `LICENSE`
   Then delete the remaining contents of `App/Resources/JetBrainsMono/` and
   `App/Resources/Newsreader/` (all other weights, variable fonts, italics,
   `.DS_Store`), and remove the now-empty directories.

2. **Update `Package.swift`** -- add `resources: [.process("Resources")]` to the
   `DesignSystem` target so `Bundle.module` includes the font files.

3. **Re-value `Tokens.swift`** to F Sage:
   - `contentBackground` -> paper `Color(red: 0.984, green: 0.980, blue: 0.961)`
   - `hairline` -> `ink.opacity(0.11)` (warm)
   - `cardStroke` -> warm `Color(red: 0.102, green: 0.086, blue: 0.055).opacity(0.10)`
   - `neutralChip` -> `ink.opacity(0.06)` (warm)
   - `speakerChipBackground` -> `sage.opacity(0.08)` (accentWashSoft)
   - `accentWashSoft` -> `sage.opacity(0.08)`
   - `accentWashStrong` -> `sage.opacity(0.14)`
   - `liveGreen` -> alias to `sage` (`Color(red: 0.306, green: 0.490, blue: 0.361)`)
   - `recordingRed` stays `.red`
   - `avatarPalette` unchanged
   - Add font semantic tokens: `serifGreeting`, `serifHeadline`, `monoDate`,
     `monoMeta`, `monoMetaMedium`, `monoStat`, `monoBadge`, `monoKicker`,
     `monoElapsed`, `monoCaption`; update `greetingFont`/`greetingTracking`,
     `dateLine`, `groupLabel`/`groupLabelTracking`, `statChipText`,
     `elapsedTimeFont`.

4. **Create `Color+Theme.swift`** with `Color` extensions for the full palette
   (`paper`, `ink`, `sage`, `inkSecondary`, `inkTertiary`, `hairline`,
   `neutralChip`, `cardStroke`, `accentWashStrong`, `accentWashSoft`) plus
   `ShapeStyle where Self == Color` sugar.

5. **Create `Font+Theme.swift`** with `Font.biscottiSerif(_:)`,
   `Font.biscottiMono(_:weight:)`, and a `MonoWeight` enum with PostScript
   names. Also the full semantic ramp tokens as `Font` statics.

6. **Create `FontRegistration.swift`** with the idempotent
   `FontRegistration.ensure()` backed by `CTFontManagerRegisterFontsForURL`.

7. **Create `Modifiers.swift`** with the `.kicker()` view modifier (mono 10.5,
   medium, uppercase, tracking +1.47).

8. **App integration** (`BiscottiApp.swift`):
   - Add `FontRegistration.ensure()` call in `WindowRootView.body` `.onAppear`.
   - Add `.tint(.sage)` on `AppShellView(...)`.
   - Add `AccentColor` color set to `Assets.xcassets` set to sage `#4E7D5C`.

9. **Test: `FontRegistrationTests.swift`** in `DesignSystemTests/` --
   after calling `FontRegistration.ensure()`, assert each pinned PostScript
   name resolves via `NSFont(name:size:)`.

## Tests

- `testJetBrainsMonoRegularRegistered`: after `ensure()`, assert
  `NSFont(name: "JetBrainsMono-Regular", size: 12)` is non-nil.
- `testJetBrainsMonoMediumRegistered`: same for `JetBrainsMono-Medium`.
- `testNewsreaderDisplayMediumRegistered`: same for
  `NewsreaderDisplay-Medium` (or the actual PostScript name found in the
  file; adjusted at implementation time).
