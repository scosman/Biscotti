---
status: complete
---

# Reskin — "F · Sage + Pressroom type"

## What this is

A **visual re-skin** of the Biscotti app: new colors, fonts, and surface
treatments applied across **every screen**. This is a **design change only** —
no layout, structure, content, navigation, interaction, or behavior changes.
Functionality stays identical; only the paint changes.

The new identity is editorial/"of-record": a **warm ivory paper** background,
**warm near-black ink**, a **muted sage green** primary (replacing systemBlue),
a **serif** (Newsreader) for greetings/wordmark, and a **monospace** (IBM Plex
Mono) for all numbers and uppercase kicker labels. SF Pro remains the workhorse
for titles and body.

A design agent produced a detailed token spec for the **Home** surface (Rev F →
"F · Sage + Pressroom type"). That spec is the canonical source for the new
token *values*. This project takes that as the starting point and:

1. **Lifts it into reusable, native-SwiftUI style primitives** — a single
   palette, type ramp, and set of reusable components/modifiers living in the
   `DesignSystem` module — rather than one-off styling on the Home screen.
2. **Applies the new identity consistently to all screens** — Home, the app
   shell (sidebar + window wall), Meeting List, Meeting Detail / Event Preview,
   Recording, Onboarding, Settings, and the Menu Bar surfaces.

## Key constraints

- **Re-skin only.** The design agent is a *design* source; nothing it says is
  intended to change UX/functionality. Preserve all existing layout, spacing,
  composition, interaction logic (chevron-vs-button rules, soon-row hero
  treatment, avatar stacking, etc.), copy, and behavior. Token *values* and the
  font/color *vocabulary* change; the *structure* does not.
- **Most-native-SwiftUI theming.** Use idiomatic SwiftUI mechanisms for the
  palette, fonts, and reusable styles (semantic `Color`/`ShapeStyle`/`Font`
  vocabulary, `ViewModifier`s, `ButtonStyle`s, an app-wide accent/tint, custom
  bundled fonts via `Font.custom` + runtime registration). Avoid hand-rolled
  theming infrastructure where a built-in idiom exists.
- **Centralize the design language.** All new colors/fonts/spacing/radii flow
  through the `DesignSystem` module's tokens and components. Screens consume
  named, semantic tokens — no raw hex/`Color.accentColor`/system-font literals
  scattered across views.
- **Apple Silicon, macOS 15 (Tahoe), light mode only.** Single theme — no
  dark-mode variant required.
- **Fonts** (Newsreader serif, IBM Plex Mono) are open-source (SIL OFL) and
  bundled with the app (not relying on system availability).

## Canonical token reference

The design agent's "Rev F → F · Sage" guide is the source of truth for the new
token *values* (typography ramp, ivory paper surfaces, sage primary, the
`lock.shield.fill` brand mark, and the Record-button color decision). The
functional/UI-design specs in this project generalize those values into the
app-wide design language and define how each screen adopts them.
