---
status: complete
---

# Dark Mode — Architecture

Mechanism and file-level design for the dark-mode token migration. Grounded in the
functional spec's token map (`functional_spec.md`). Mechanism chosen with the
user: **Swift dynamic colors** (not an asset catalog).

UI-design step is intentionally skipped — no screens, layout, navigation, or
behavior change. Component-design docs are not needed — the whole change
centralizes in `DesignSystem` plus a short, enumerated list of call-site repoints.

---

## 1. Mechanism: one dynamic helper, two value branches

There is no pure-SwiftUI dynamic-color primitive on macOS 15, but AppKit's
`NSColor(name:dynamicProvider:)` resolves per `NSAppearance` at draw time, and
`Color(nsColor:)` bridges that into SwiftUI so it re-resolves against the view's
appearance. This gives us:

- a **single** definition per token (one light `NSColor`, one dark `NSColor`),
- automatic resolution with **zero `colorScheme` branches in views**,
- one source feeding **both** SwiftUI (`Color`) and AppKit (`NSColor`) — removing
  today's hand-synced duplication.

The only appearance switch in the entire codebase lives here:

```swift
// DesignSystem/DynamicColor.swift  (internal)
import AppKit
import SwiftUI

/// The single point where appearance is resolved. Returns an NSColor that
/// picks `dark` under .darkAqua and `light` otherwise. Both inputs are sRGB
/// and Sendable, so this is concurrency-safe under Swift 6.
func dynamicNSColor(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
}

/// SwiftUI sugar: a dynamic `Color` from light/dark sRGB literals.
func dynamicColor(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: dynamicNSColor(light: light, dark: dark))
}
```

> Future-proofing (out of scope now): `bestMatch(from:)` can be widened to
> `[.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]`
> to add Increased-Contrast variants without touching any call site. We do not do
> this now (it would require defining HC values and must not affect light).

### Why this is byte-identical for light

Every token's **light** branch is `NSColor(srgbRed: r, green: g, blue: b, alpha: a)`
with the **exact same literals** the code uses today. The codebase already trusts
this construction: `Color+Theme.swift` today maintains `NSColor(srgbRed: …)`
mirrors built from "the same RGB/alpha literals … to avoid color-space surprises."
We are simply making the `Color` token *derive from* that same sRGB `NSColor`
(via `Color(nsColor:)`) instead of from a parallel `Color(red:…)` literal — and
adding a dark branch. Light resolution returns the identical sRGB color.

This equivalence is **asserted by an automated test** (§4), so it isn't taken on
faith.

---

## 2. File changes

### 2.1 `DesignSystem/DynamicColor.swift` (new, internal)
The helper above. Internal to the `DesignSystem` module.

### 2.2 `DesignSystem/Color+Theme.swift` (rewrite, behavior-preserving for light)
Convert every semantic token from a static literal into a `dynamicColor(light:dark:)`.

Pattern — define the `NSColor` tokens from light/dark sRGB, then derive the
`Color` tokens and `ShapeStyle` sugar from them (single source):

```swift
public extension NSColor {
    static let ink = dynamicNSColor(
        light: NSColor(srgbRed: 0.102, green: 0.094, blue: 0.075, alpha: 1),      // #1A1813
        dark:  NSColor(srgbRed: 0.969, green: 0.949, blue: 0.910, alpha: 1)       // #F7F2E8
    )
    static let inkSecondary = dynamicNSColor(
        light: NSColor(srgbRed: 0.102, green: 0.094, blue: 0.075, alpha: 0.54),
        dark:  NSColor(srgbRed: 0.969, green: 0.949, blue: 0.910, alpha: 0.58)
    )
    // … inkTertiary, sage, cardStroke, accentWashStrong, findHighlightFocused …
}

public extension Color {
    static let ink = Color(nsColor: .ink)
    static let inkSecondary = Color(nsColor: .inkSecondary)
    // … etc.
}
```

Notes on this rewrite:
- **Derived tokens become explicit two-value entries.** `inkSecondary`,
  `inkTertiary`, `hairline`, `neutralChip`, `accentWashSoft/Strong`, `softSageFill`
  are no longer `base.opacity(x)` — each gets explicit light/dark `NSColor`s so the
  dark alpha (and brightened dark base) can differ from light per the token map.
- **NSColor mirrors that don't exist today** (e.g. an NSColor for `paper`,
  `warningOchre`, washes) are only added where an AppKit consumer needs them. The
  current AppKit consumers are `ink`, `inkSecondary` (markdown editor) — those
  must stay NSColor-backed. For SwiftUI-only tokens we can define the dynamic
  `Color` directly via `dynamicColor(light:dark:)` without a public `NSColor`.
- **New tokens added here:** `accentFill`, `read`, `elevatedFill`, `accentTrack`,
  `signalRedText`, `cardShadow`, `controlShadow` (values per functional spec §3).
- **`ShapeStyle` sugar** (`static var ink: Color { .ink }`, etc.) is preserved and
  extended for the new tokens used as `ShapeStyle` (`.foregroundStyle(.read)`,
  `.fill(.accentFill)`, `.fill(.signalRedText)`).
- The big doc-comments on `signalRed` / `warningOchre` ("the single canonical red /
  warning") are updated to note the dark-only text variant (`signalRedText`) and
  that values are now appearance-adaptive — preserving the "don't introduce other
  reds/yellows" guidance.

### 2.3 `DesignSystem/Tokens.swift` (mostly mechanical)
`Tokens.*` are thin aliases of `Color.*`. Update:
- `cardFill = Color.white` → `cardFill = Color.cardFill` (new adaptive token:
  light `#FFFFFF`, dark `#1A170F`). Every card surface adapts for free.
- `warningChipText = Color.warningChipText` — redefine the underlying token to its
  own dark value (`#F0C04A`), no longer `= warningOchre`.
- `warningBackground` / `warningChipFill` / `errorBackground` stay expressed as
  `…ochre/red.opacity(0.15)`; they auto-adapt once `warningOchre` / `signalRed`
  are dynamic (the opacity composites over the adaptive base — but verify the
  dark alpha lands per spec; if a precise dark alpha is required, promote to an
  explicit dynamic token).
- Add `Tokens.elevatedFill`, `Tokens.accentFill`, `Tokens.read`,
  `Tokens.accentTrack`, `Tokens.signalRedText`, `Tokens.cardShadow`,
  `Tokens.controlShadow` aliases (match the existing aliasing style so call sites
  can use either `Color.x` or `Tokens.x` as they do today).
- `avatarPalette`, all typography/spacing/radii tokens: **untouched.**

> Decision: opacity-derived washes (`warningBackground`, `errorBackground`,
> `recordingTintSoft`, `recordingHoverFill`) may stay as `base.opacity(x)` ONLY
> where the resulting dark value matches the spec within tolerance; otherwise make
> them explicit dynamic tokens. The §4 dark-resolution test catches mismatches.

### 2.4 Call-site repoints (≈16 sites)
Exactly the list in functional spec §4. These are 1–2 token-name swaps each, in:
`JoinRecordButtonStyle`, `OnboardingPrimaryButtonStyle`, `AppShellView` (toolbar
fill), `GrantedTag`, `LightAlertButtonStyle` (fill + shadow), `EditableMeetingTitle`,
`TranscriptListView`, `RecordingView`, `AutoStopCountdownCard`, `EventPickerSheet`,
`ManageModelsSheet`, `ModelDownloadCard`, `ProgressHeader`, `HomeCardModifier`.

### 2.5 `MarkdownEditorConfiguration+Biscotti.swift`
No edit needed beyond the token redefinition: it reads `NSColor.ink` /
`NSColor.inkSecondary`, which become dynamic — the `NSTextView` adapts to the
window's `effectiveAppearance` automatically. Verify the editor re-renders on a
live appearance switch (it should, via standard AppKit appearance propagation).

### 2.6 App / window level
No change required. The app sets no `preferredColorScheme`; `AppShellView` paints
`Color.wall` (now adaptive) as the window backdrop and `Color.sidebarTint` (now
adaptive) on the sidebar. The title bar / toolbar / dividers / sheets are native
and adapt. Confirm no stray `.preferredColorScheme(.light)` exists (verified: none).

---

## 3. Concurrency / Swift 6 notes

- The repo builds with strict concurrency + warnings-as-errors. Static `let`
  tokens of type `Color` (Sendable) and `NSColor` are already used today and pass
  CI, so the new static `let`s are fine.
- `dynamicNSColor`'s provider closure captures two `NSColor`s and a small
  `[NSAppearance.Name]` array (Strings) — all Sendable — so it satisfies a
  `@Sendable` provider requirement if the SDK imposes one. If the compiler flags
  the closure, the fix is local to the helper (e.g. mark inputs explicitly), not
  the call sites.
- Validate by building through `hooks-mcp` (agent cannot run `swift build` in the
  Bash sandbox).

---

## 4. Testing — the linchpin guarantees, automated in `swift test`

A new `DesignSystemTests` suite resolves each token under both appearances and
asserts components. This makes both hard guarantees machine-checked and runs
without xcodebuild.

Resolve a dynamic `NSColor` for a given appearance deterministically:

```swift
func components(_ color: NSColor, _ appearanceName: NSAppearance.Name)
    -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
    var out = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
    NSAppearance(named: appearanceName)!.performAsCurrentDrawingAppearance {
        let c = color.usingColorSpace(.sRGB)!
        out = (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }
    return out
}
```

**Test 1 — light is byte-identical (the critical regression guard).** For every
token, assert its `.aqua` resolution equals the **legacy literal** it replaced
(keep a table of the old `Color(red:…)`/opacity values in the test). Tolerance
≈ 1/512 (sub-8-bit). This is the automated proof that light didn't move.

**Test 2 — dark matches the design.** For every token, assert its `.darkAqua`
resolution equals the design hex (within the same tolerance).

**Test 3 — no view conditionals.** A test (or CI grep) asserts zero
`colorScheme ==` / `@Environment(\.colorScheme)` occurrences under
`Packages/BiscottiKit/Sources/**` view code (the only allowed appearance logic is
in `DynamicColor.swift`).

> `performAsCurrentDrawingAppearance` (macOS 11+) is deterministic and
> single-threaded here; resolving at the `NSColor` layer avoids any ambiguity in
> how SwiftUI bridges the dynamic color, and it directly validates the AppKit
> consumers too.

Existing `DesignSystemTests` and other package tests must stay green
(`make test` / `mcp__hooks-mcp__test`).

---

## 5. Manual / on-hardware verification (non-gating, human)

Toggle System Settings → Appearance while the app is open and confirm a **live**
switch (no relaunch) across: Home, Meeting Detail (transcript + notes), Active
Recording (Stop&Save, REC pill, Elapsed + amber ≤5:00 chips, RECORDING badge),
Upcoming, Onboarding, Settings, model sheets, error + warning banners, menu-bar
popover, and the markdown notes editor. No white-on-light or light-on-light
defects; avatars unchanged; native controls correct.

This is captured as the dark-mode acceptance pass; it does not change the
manual-test gate for Transcription/AudioCapture/LocalLLM (no package touched
there).

---

## 6. Risks & mitigations

| Risk | Mitigation |
|---|---|
| `Color(nsColor: srgb)` ≠ today's `Color(red:)` for light | Test 1 asserts exact light components; if any token drifts, construct that `Color` via `Color(.sRGB, red:…)` to match. High confidence both are plain sRGB. |
| Opacity-derived washes land at wrong dark alpha | Test 2 catches it; promote the token to an explicit dynamic light/dark entry. |
| AppKit text view doesn't live-update on appearance switch | Standard appearance propagation should handle it; manual §5 confirms; if not, observe `effectiveAppearance` in the editor config (localized fix). |
| Swift 6 `@Sendable` provider error | Captured values are Sendable; fix is local to the helper. |
| A repoint accidentally changes a light pixel | Each new token's light value == the literal it replaces (Test 1 covers the token; repoints only swap which equal-in-light token is used). |
