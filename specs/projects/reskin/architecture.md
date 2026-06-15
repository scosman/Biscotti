---
status: complete
---

# Architecture — Reskin theming layer

How the F · Sage design language (see `ui_design.md`) is implemented in the
**most native SwiftUI** way, where it lives, how fonts are bundled, and the
per-file migration map. The values are in `ui_design.md`; this doc is the
*mechanism*.

Decision recap (from planning): **semantic tokens + native idioms**, single
static light theme — **no** Environment-injected `Theme` object, **no** runtime
theme switching.

---

## 1. Theming mechanism (the native idioms)

All of this lives in the existing **`DesignSystem`** SPM module (every UI package
already depends on it).

### 1a. Colors — `Color` + `ShapeStyle` extensions

Express the palette as a named `Color` set plus the idiomatic `ShapeStyle`
sugar, so call sites read natively:

```swift
public extension Color {
    static let paper        = Color(red: 0.984, green: 0.980, blue: 0.961)
    static let ink          = Color(red: 0.102, green: 0.094, blue: 0.075)
    static let sage         = Color(red: 0.306, green: 0.490, blue: 0.361)
    static let inkSecondary = ink.opacity(0.54)
    static let inkTertiary  = ink.opacity(0.34)
    static let hairline     = ink.opacity(0.11)
    static let neutralChip  = ink.opacity(0.06)
    static let cardStroke   = Color(red: 0.102, green: 0.086, blue: 0.055).opacity(0.10)
    static let accentWashStrong = sage.opacity(0.14)
    static let accentWashSoft   = sage.opacity(0.08)
    // recordingRed stays system red.
}

// Idiomatic sugar so `.foregroundStyle(.ink)`, `.fill(.sage)`, `.background(.paper)` work:
public extension ShapeStyle where Self == Color {
    static var paper: Color { .paper }
    static var ink: Color { .ink }
    static var sage: Color { .sage }
    static var inkSecondary: Color { .inkSecondary }
    static var inkTertiary: Color { .inkTertiary }
    // …one per token used as a ShapeStyle
}
```

**`Tokens` stays as the single backing store of raw values**, re-valued to F ·
Sage, and the `Color`/`ShapeStyle` extensions reference it (or vice-versa) so
there is exactly one source of truth. Existing `Tokens.contentBackground` etc.
keep working (re-valued); new/ad-hoc call sites move to the semantic `.ink` /
`.sage` sugar. Net: no duplicate color definitions.

### 1b. Fonts — `Font` helpers + semantic tokens

```swift
public extension Font {
    /// Newsreader Display (serif), weight 500. Registration is ensured on first use.
    static func biscottiSerif(_ size: CGFloat) -> Font {
        FontRegistration.ensure()
        return .custom("NewsreaderDisplay-Medium", size: size)
    }
    /// JetBrains Mono, tabular figures.
    static func biscottiMono(_ size: CGFloat, weight: MonoWeight = .regular) -> Font {
        FontRegistration.ensure()
        return .custom(weight.postScriptName, size: size)   // "JetBrainsMono-Regular" / "-Medium"
    }
}
```

- Reference fonts by **PostScript name** (e.g. `NewsreaderDisplay-Medium`,
  `JetBrainsMono-Regular`/`-Medium`), not by family + `.weight()` — custom
  families don't reliably synthesize weights, so each weight is its own
  registered file/name. Verify the exact PostScript names after bundling (via
  `CTFontManagerCopyAvailablePostScriptNames` or Font Book) and pin them.
- The semantic ramp tokens from `ui_design.md` §2 (`serifGreeting`,
  `serifHeadline`, `monoDate`, `monoMeta`, `monoMetaMedium`, `monoStat`,
  `monoBadge`, `monoKicker`, `monoElapsed`, `monoCaption`) are defined on
  `Tokens`/`Font` in terms of these helpers.
- **Tracking / uppercase** (kicker = +0.14em uppercase; greeting = −0.32) are
  view modifiers, not part of `Font`. Provide a `.kicker()` `ViewModifier`
  (`.font(monoKicker).textCase(.uppercase).tracking(...)`) so kickers are one
  call. Greeting tracking stays a `.tracking()` at the call site (as today).

### 1c. Modifiers & styles (already-native, reused/extended)

- `HomeCardModifier` (`.homeCard()`) and `InsetDivider` exist — only their color
  tokens change.
- `JoinRecordButtonStyle` (`ButtonStyle`) exists — fill → `.sage`.
- New `.kicker()` `ViewModifier` (above).
- App accent/tint: see §4.

No Environment `Theme`, no protocol-witness theme machinery — just extensions,
modifiers, and styles. That is the idiomatic SwiftUI surface.

---

## 2. Where it lives (DesignSystem module layout)

```
Packages/BiscottiKit/Sources/DesignSystem/
  Tokens.swift            # re-valued raw values (single source of truth)
  Color+Theme.swift       # NEW: Color + ShapeStyle semantic sugar
  Font+Theme.swift        # NEW: Font helpers + semantic ramp tokens
  FontRegistration.swift  # NEW: idempotent runtime registration of bundled TTFs
  Modifiers.swift         # NEW: .kicker() (and any small shared modifiers)
  Resources/Fonts/        # NEW: bundled TTFs + license files
  …existing components (re-tokenized)…
```

`Package.swift` — add resources to the `DesignSystem` target:

```swift
.target(
    name: "DesignSystem",
    resources: [.process("Resources")],
    swiftSettings: warningsAsErrors
),
```

---

## 3. Fonts — bundling & registration

### 3a. Files to bundle (move, prune the rest)

The user dropped full font folders into `App/Resources/{JetBrainsMono,Newsreader}`.
**Move only the needed static TTFs into the package**, keep each license, and
**delete everything else** (webfonts, variable fonts, italics, unused weights,
`.DS_Store`) and the now-empty `App/Resources/{JetBrainsMono,Newsreader}` folders.

Move into `DesignSystem/Resources/Fonts/`:

| From | Keep |
|---|---|
| `App/Resources/JetBrainsMono/fonts/ttf/JetBrainsMono-Regular.ttf` | ✅ |
| `App/Resources/JetBrainsMono/fonts/ttf/JetBrainsMono-Medium.ttf` | ✅ |
| `App/Resources/JetBrainsMono/OFL.txt` | ✅ (license) |
| `App/Resources/Newsreader/Fonts-TTF/NewsreaderDisplay-Medium.ttf` | ✅ |
| `App/Resources/Newsreader/Fonts-TTF/NewsreaderDisplay-Regular.ttf` | optional (only if a lighter headline is wanted) |
| `App/Resources/Newsreader/LICENSE` | ✅ (license) |
| everything else (webfonts/variable/italics/other weights/NL/.DS_Store) | ❌ delete |

> A licenses/attribution screen is already TODO for Project 9 (see
> `BiscottiApp.swift`); bundling the OFL/LICENSE files here keeps us compliant
> and ready for that screen.

### 3b. Registration (runtime, idempotent, preview-safe)

```swift
public enum FontRegistration {
    private static let _registerOnce: Void = {
        let names = ["JetBrainsMono-Regular", "JetBrainsMono-Medium", "NewsreaderDisplay-Medium"]
        for name in names {
            guard let url = Bundle.module.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
    public static func ensure() { _ = _registerOnce }
}
```

- `Bundle.module` resolves the `DesignSystem` resource bundle — works from **any**
  UI package and in **SwiftUI previews** (no app-target involvement, no
  `ATSApplicationFontsPath`). This is why fonts live in the package, not the app.
- `ensure()` is called by the `Font.biscotti*` helpers (lazy, first-use) **and**
  once explicitly at app launch (`DesignSystem`-level call from `BiscottiApp`)
  so registration is warm before first paint.
- Idempotent via the `static let` once-guard; duplicate `.process`-scope
  registration is harmless but the guard avoids churn/log noise.

### 3c. Name resolution caveat

`Font.custom` matches the **PostScript name**. After moving the files, confirm
the actual names (Newsreader's may be e.g. `Newsreader18pt-Display-Medium` or
`NewsreaderDisplay-Medium` depending on build) and pin them in `Font+Theme.swift`.
A `DesignSystemTests` test asserts each expected name is registered (fails loudly
if a name is wrong) — see §6.

---

## 4. App integration

In `App/Sources/BiscottiApp.swift`:

1. **Register fonts at launch** — call `FontRegistration.ensure()` (re-exported
   from `DesignSystem`) in `applicationDidFinishLaunching` (or `WindowRootView`
   `.onAppear`), before the first content paint.
2. **App-wide tint** — apply `.tint(.sage)` to the window root content
   (`AppShellView`) and any other window/scene roots, so native controls
   (buttons, toggles, focus rings) tint sage.
3. **`AccentColor` asset** — add an `AccentColor` color set (= sage `#4E7D5C`) to
   `App/Resources/Assets.xcassets`. This makes any residual `Color.accentColor`
   and system chrome resolve to sage as a catch-all. (Call sites still migrate to
   `.sage`; the asset is belt-and-suspenders.)
4. **Window wall + sidebar tint** — *best-effort native seam:*
   - Content/window background: set the `wall` radial gradient as the background
     of the window root (`.background(...)` on `WindowRootView`).
   - Sidebar: overlay `sidebarTint` on the system sidebar material (e.g.
     `.background(.regularMaterial)` + an ivory overlay, or
     `.scrollContentBackground(.hidden)` + background where supported).
   - If a faithful radial wall isn't natively reachable through
     `NavigationSplitView`, fall back to a **flat warm-grey** (`#E4E1D8`) — do
     **not** resort to AppKit `NSWindow` surgery for the reskin. Flag the final
     look for the human visual check (§6). Home already paints its own `paper`
     background, so the content pane is covered regardless.

---

## 5. Migration map (per file)

Concise call-site changes. Token names per `ui_design.md`. "warm neutrals" =
replace `.primary/.secondary/.tertiary` and `Color.black.opacity(…)` /
`Color.secondary.opacity(…)` with `.ink / .inkSecondary / .inkTertiary /
.hairline / .neutralChip`. "accent → sage" = replace `Color.accentColor` /
`.accentColor` with `.sage` (or the wash tokens).

**DesignSystem (do first — highest leverage):**
- `Tokens.swift` — re-value all color constants to F · Sage; repoint font tokens
  to the mono/serif ramp; `liveGreen` → alias `sage`; keep `recordingRed = .red`;
  keep `avatarPalette`. Add the new mono/serif semantic tokens.
- `Color+Theme.swift`, `Font+Theme.swift`, `FontRegistration.swift`,
  `Modifiers.swift` (`.kicker()`) — new files (§1–3).
- `Avatar.swift` — "+N" badge → `monoBadge` + `inkSecondary`; `RecordingAvatar`
  grey → warm; rings warm.
- `StatChip.swift` — value → `monoStat`/`inkSecondary`; default icon tint sage;
  fill `neutralChip`.
- `UpcomingEventRow.swift` — `timeLabel` → `monoMeta`/`inkSecondary` (drop
  `.monospacedDigit()`); badge fill warm.
- `MeetingPlatformChip.swift` — video icon `liveGreen`→`sage`; fill
  `ink.opacity(0.06)`; label SF Pro.
- `HomeCardModifier.swift` — stroke `cardStroke`, shadow unchanged; `InsetDivider`
  → `hairline`.
- `JoinRecordButtonStyle.swift` — `Color.accentColor` fill → `.sage`.
- `TranscriptSegmentRow.swift` — speaker chip bg → `accentWashSoft`.
- `StatusRow.swift` — success checkmark `.green` → `.sage`; text `inkSecondary`.
- `Banner.swift` — keep warning amber / error red; text → `inkSecondary` if used.
- `AudioTransport.swift` — times → `monoCaption` (drop `.monospacedDigit()`).
- `CalendarContextBlock.swift` — text → `inkSecondary`; keep calendar hex dot.
- `RecordButton.swift` (unused) — dot → `.sage` (idle affordance) or leave.

**HomeUI/HomeView.swift** — greeting `Tokens.greetingFont` → `serifGreeting`
(tracking −0.32); `dateText` → `monoDate`; stat chip `tint: .accentColor` →
`.sage` (l.67) and `Tokens.liveGreen` → `.sage` (l.74); hero/ordinary countdown
`Color.accentColor` → `.sage` + `monoMetaMedium` (l.198–200, 274–276); times
`formattedTime` → `monoMeta` (l.202, 278); pastSecondLine → `monoMeta` (l.382);
"See all"/links `Color.accentColor` → `.sage` (l.276, 323); chevrons `.tertiary`
→ `.inkTertiary` (l.292, 392); kickers via `.kicker()` (l.291 group label helper,
l.425–431); footer — add sage `lock.shield.fill`, wordmark stays SF Pro
(l.408–414); `.primary/.secondary` → `.ink/.inkSecondary`; `contentBackground`
re-valued to `paper`. Small in-card empties (l.119, 338) stay SF Pro `metaText`.

**AppShellUI/AppShellView.swift** — **add sidebar brand lockup** (§5a of
ui_design) above `homeRow`; selected-nav glyph/tint `Color.accentColor` →
`.sage` (l.173, 200, 231) and selection wash `…opacity(0.15)` →
`accentWashStrong` (l.186, 213, 244, 316); idle Record icon/tint
`Tokens.recordingRed` → `.sage` (l.106) and make the bordered button sage; active
"Recording…" stays red (l.98); counter → `monoMeta` (l.94); section kicker
"UPCOMING" → `.kicker()` (l.294–295); search field `.quinary` → warm neutral;
`.secondary` → `.inkSecondary`. Apply `.tint(.sage)` and the wall/sidebar
treatment (§4) at this view's roots.

**MeetingListUI/MeetingListView.swift** — `.body`/`metadataFont` text →
`.ink/.inkSecondary`; any time/duration → `monoMeta`; `ContentUnavailableView`
"No Recordings" title → `serifHeadline` via label closure.

**MeetingDetailUI/MeetingDetailView.swift + EventPreviewView.swift** — warm
neutrals; metadata dates/times → `monoMeta`; section kickers
(`sectionHeaderFont`) → `.kicker()`; accent wash `Color.accentColor.opacity(0.08)`
→ `accentWashSoft` (MeetingDetail l.259); error `.red` stays (l.456); speaker/
chips → sage wash.

**RecordingUI/RecordingView.swift** — elapsed `Tokens.elapsedTimeFont` →
`monoElapsed` (drop `.monospacedDigit()`); **everything else unchanged** (red
pulsing dot, red Stop, `recordingRed`). Title `metadataFont` → `inkSecondary`.

**OnboardingUI/OnboardingView.swift + OnboardingStepViews.swift** — step
headline(s) `.title2`/semibold → `serifHeadline`; success checkmarks `.green` →
`.sage` (l.156, 180, 320); body/metadata → `.inkSecondary`; calendar color dots
keep hex.

**SettingsUI/SettingsView.swift** — warm neutrals; SF Pro stays; calendar color
dots keep hex; numeric/version text → `monoMeta` where it reads as data.

**MenuBarUI/** — **no change** to the native `.menu` dropdown (intentional, per
functional spec §5). `MenuBarLabelView` keeps icon + `.monospacedDigit()` (a
mono switch here is optional and low value).

**App/Sources/BiscottiApp.swift** — `FontRegistration.ensure()` at launch;
`.tint(.sage)`; error view `.red`/`.secondary` may warm but is incidental.

---

## 6. Testing & verification

- **Unit (DesignSystem target, `swift test`):**
  - Font registration test: after `FontRegistration.ensure()`, assert each
    pinned PostScript name is available (`CTFontManagerCopyAvailablePostScriptNames`
    contains it / `NSFont(name:size:)` is non-nil). Catches name drift.
  - Token presence/value sanity (cheap): the new tokens compile and resolve.
- **Build/lint:** `make ci` (lint + test + build) must stay green;
  `make build-app` must build with the new resource bundle.
- **Visual (human):** SwiftUI previews per component/screen are the fast loop;
  a real `make build-app` run is the final check — especially for the
  **window wall / sidebar material** seam (§4) and the **ContentUnavailableView
  serif** (confirm it reads well, else fall back to SF Pro). No snapshot-test
  infra exists; do not add it for this project.
- **Manual-test gate:** untouched — changes are in UI + `DesignSystem`, not
  `Packages/Transcription` or `Packages/AudioCapture`, so
  `make manual-tests-check` is not affected.

---

## 7. Risks & open seams

- **Custom font name resolution** (3c) — the single most likely snag; the
  registration test de-risks it. Verify Newsreader's Display PostScript name
  early.
- **Window wall / sidebar material** (§4) — native customization of
  `NavigationSplitView` chrome is limited; accept the flat fallback rather than
  AppKit window hacks. Visual-check on hardware.
- **`ShapeStyle where Self == Color` sugar** — ensure the static-var names don't
  collide with SwiftUI's own (`.secondary`, `.tertiary` exist as Hierarchical
  ShapeStyles); use distinct names (`.inkSecondary`, not `.secondary`).
- **Warnings-as-errors** — the project treats warnings as errors; the new files
  and resource bundle must be warning-clean (no unused, no deprecated CTFont API
  surprises).

---

## 8. Component designs

**Not needed as separate docs.** The reskin's "component" is the single
DesignSystem theming layer, fully specified above (§1–3) plus the per-component
visual notes in `ui_design.md` §4. Proceed to the implementation plan.
