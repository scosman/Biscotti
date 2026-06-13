# Biscotti — Home & App Container Design Spec

**Target:** the "Ref F" home direction. This document is the source of truth for the **app container** and the **Home screen** only. Where it conflicts with the current code for these surfaces, **this spec wins** — rebuild Home to match it.

**Out of scope:** the Past Meetings list/detail (the three-pane reader), any meeting-detail view. Leave those alone.

**Platform note:** the app is SwiftUI for macOS (Tahoe, light appearance only — there is no dark theme). All icons are **SF Symbols**. All measurements below are points.

---

## 1. The core move: a "Pro" palette, not system defaults

The current build leans on stock AppKit chrome — `NSColor.windowBackgroundColor` greys, default `List` selection, default separators. That reads as generic. Replace those surfaces with the refined palette below. **The one thing we keep stock is the accent: real systemBlue (`#007AFF`), not a custom blue.**

### Palette

| Role | Value | SwiftUI |
|---|---|---|
| **Accent** | `#007AFF` (systemBlue, light) | `Color(nsColor: .systemBlue)` — set as the app/window `.tint()` |
| Accent wash (selection, soon-row) | `accent @ 6–14%` | `Color(nsColor: .systemBlue).opacity(0.14)` / `0.06` |
| **Content background** | `#FBFBFC` (near-white, faintly cool) | custom `Color`, applied to the detail pane — **not** windowBackground grey |
| Card fill | `#FFFFFF` | `Color.white` |
| Primary text | `black @ 85%` | `.primary` (or `Color.black.opacity(0.85)` for exactness) |
| Secondary text | `black @ 50%` | `.secondary` |
| Tertiary text / chevrons | `black @ 30%` | `.tertiary` |
| Hairline separator | `black @ 8%` | `Color.black.opacity(0.08)` |
| Chip fill (neutral) | `black @ 5%` | `Color.black.opacity(0.05)` |
| Success / "live" green (Meet icon, "Next in" dot) | `#1A9D5A` | custom `Color` |

### Avatar gradients (initials chips)
Avatars are **colorful**, never grey. 135° linear gradients keyed off the first initial:

| Initial | Gradient |
|---|---|
| Blue people (W, K) | `#5E9BFF → #2F6BD8` / `#8DB4FF → #4A78E0` |
| Orange (M, J) | `#FF9B6A → #F0612F` / `#FFB38A → #EF7A45` |
| Green (U) | `#7BD389 → #36A85A` |
| Purple (P) | `#C79BFF → #8A4FE0` |
| Yellow (S) | `#FFD166 → #E8A13A` |
| Teal (L) | `#6AD6C8 → #2A9D8F` |
| Pink (D) | `#FF8FA3 → #E85C75` |
| Fallback | `#9AA6B8 → #697585` |

Each avatar: circle, `inset hairline @ 12%` ring; when stacked, add a `2pt white` outer ring so overlaps read cleanly. SwiftUI: `Circle().fill(LinearGradient(...))` + initials in white `.semibold`, `.overlay(Circle().strokeBorder(.white, lineWidth: 2))` on stacked instances.

---

## 2. App container & layout

- **Shell:** `NavigationSplitView` — sidebar + detail. Detail pane background = **`#FBFBFC`** (set via a full-bleed `Color(...)` behind the content, or `.containerBackground`). Do not let the stock grey show through.
- **Home content is a single centered column.** Inside a `ScrollView`, place one `VStack(alignment: .leading)` constrained to **`maxWidth: 800`** and centered horizontally (`.frame(maxWidth: 800)` then `.frame(maxWidth: .infinity)` to center).
- **Vertical centering:** the column is centered in the viewport when content is short (the design reads as a calm, centered welcome). Use a `VStack` with `Spacer()` above and below, or center the scroll content. If content grows past the viewport it scrolls normally.
- **Padding:** `24pt` top/bottom, `32pt` leading/trailing around the column.
- **Section rhythm:** group label → card → ~26–34pt gap → next group label → card.

---

## 3. Sidebar & top app-bar — color changes ONLY

These already exist and work. Do not restructure content or behavior. Apply only these color adjustments so they sit in the Pro palette:

- **Sidebar:** keep the translucent material (warm-grey vibrancy). The change is the **selected nav row**: use the **accent wash** — `accent @ 14%` rounded background (radius 7), with the row's **SF Symbol tinted accent blue** and the label in primary text. Replace the stock solid-blue `List` selection with this softer tint. Hover (unselected): `black @ 5%`.
- **Section labels** in the sidebar ("UPCOMING"): `11pt`, `.semibold`, uppercase, `+0.5` tracking, tertiary color.
- **Top app-bar:** keep layout. Title `15pt .semibold`. The toolbar **Record pill** is the one saturated element — red gradient (`#FF6F57 → #EF3A22`), white label, pulsing white dot. Search field: `black @ 5%` fill, radius 7, tertiary placeholder. Icon buttons: tertiary glyph, `black @ 6%` hover fill.

---

## 4. Home screen — controls in detail

Build Home top-to-bottom as: **greeting block → stat chips → "Upcoming" card → "Past Meetings" card.** Everything below `4.x` describes one piece.

### 4.1 Greeting block
- **Title:** `"Good morning, {name}"` — `system(size: 32, weight: .bold)`, tracking `-0.6`, primary.
- **Date line:** `"Wednesday, June 12"` — `15pt .regular`, secondary, `5pt` below title.
- SwiftUI: two `Text` in a `VStack(alignment: .leading, spacing: 5)`.

### 4.2 Stat chips (at-a-glance row)
A horizontal row of three pill chips, `14pt` below the date. Each chip: `HStack(spacing: 5)` of a small SF Symbol + `Text`, height 24, `0/10pt` padding, `RoundedRectangle(cornerRadius: 7)` filled `black @ 5%`, text `12.5pt .medium` secondary.
- `calendar` (accent blue) · "5 meetings today"
- `clock` (default/secondary) · "2h 10m scheduled"
- `circle.fill` small (green `#1A9D5A`) · "Next in 6m"

Build as one reusable `StatChip(icon:tint:text:)` view; lay out in `HStack(spacing: 8)`.

### 4.3 Group label
`"UPCOMING"` / `"PAST MEETINGS"` — `11.5pt .semibold`, uppercase, `+0.5` tracking, secondary, ~`9pt` above its card, `4pt` leading inset.
For "Past Meetings," put a **"See all ›"** trailing link on the same baseline — accent color, `12.5pt`, with a small `chevron.right` (`12pt`). Use an `HStack` with `Spacer()` between label and link.

### 4.4 The card
Each group's rows live in one card:
- `Color.white`, `cornerRadius: 12`, clipped.
- Depth = **hairline + whisper shadow**, not a heavy elevation: `stroke black @ 7%` (0.5pt) **plus** `shadow(color: black @ 5%, radius: 1.5, y: 1)`.
- Rows stacked in `VStack(spacing: 0)` with an **inset hairline divider** between rows: `black @ 8%`, 0.5pt, inset `14pt` from the leading edge (aligns under the text, not the avatars). First row has no top divider.
- **Do not use a plain `List`** — it fights this card styling. Compose rows manually.

### 4.5 Fixed avatar column (alignment rule)
Every row starts with a **fixed-width 78pt** avatar column so **all titles align at the same X** regardless of participant count. Inside: up to **3** overlapped circle avatars, then a **"+N"** grey badge if more. Overlap offset ≈ 66% of avatar size (negative leading). Avatar size: 28pt on the soon-row, 26pt elsewhere. SwiftUI: an `HStack(spacing: -offset)` pinned to `.frame(width: 78, alignment: .leading)`.

### 4.6 "Starting soon" hero row (first Upcoming row only)
The imminent meeting is emphasized; it is the only actionable row, so it carries **buttons instead of a chevron**.
- **Row background:** `accent @ 6%` wash (subtle blue tint), `18pt` padding, vertically centered.
- **Avatar column** (28pt avatars).
- **Center stack:**
  - Baseline `HStack(spacing: 9)`: title `16pt .semibold` + participant names `12.5pt` secondary (truncating).
  - Meta `HStack(spacing: 9)` `6pt` below: **countdown in accent, `.semibold`** ("in 6m") · time ("9:00 AM") · **Meet chip**.
  - Description line `12.5pt` secondary, `8pt` below, single-line truncating.
- **Trailing action stack** (`VStack(spacing: 9)`, `16pt` leading margin):
  - **"Join & Record"** — filled accent button: `accent` fill, white `13.5pt .semibold`, leading `record.circle`/`largecircle.fill.circle` SF Symbol, height 32, radius 8, inner top highlight. Use a custom `ButtonStyle` (don't rely on `.borderedProminent` default metrics).
  - **"View in calendar"** — quiet text link, `12.5pt` secondary, accent on hover.

### 4.7 Upcoming rows (non-hero)
- `11/14pt` padding, avatar column (26pt).
- Title `14.5pt .medium`; meta line `12.5pt` secondary: **countdown accent `.medium`** · time · Meet chip.
- **Trailing: `chevron.right` only**, tertiary color, ~15pt. **No Join button** — you won't record a meeting 14 hours out.

### 4.8 Past rows
- Avatar column (26pt), title `14.5pt .medium`, meta `12.5pt` secondary = `"Today · 32m · {names}"`.
- **Trailing: `chevron.right`**, tertiary.

### 4.9 Meet chip (reusable)
Inline capsule: `video.fill` SF Symbol (green `#1A9D5A`) + label ("Google Meet"), `11pt .medium` secondary, height 19, `0/7pt` padding, radius 6, `black @ 6%` fill.

---

## 5. Design decisions to preserve

1. **Title alignment via a fixed avatar column.** Titles must line up on a single vertical axis; the 78pt column guarantees it whether a meeting has 1 or 9 people. Never let avatar count push titles around.
2. **Chevrons mean "drill in"; buttons mean "act now."** Static rows (future upcoming, past) get a single trailing `chevron.right` and nothing else. The one row you can act on right now (the soon-row) drops the chevron and shows real buttons. Don't put both on a row.
3. **Accent is for time-sensitivity, not decoration.** Blue appears on the live countdown, the primary action, links, and the selected nav tint — nowhere else. The "starting soon" row earns a 6% blue wash; ordinary rows stay white.
4. **One saturated element per region.** Sidebar/content are quiet; the toolbar Record pill (red) and the soon-row Join button (blue) are the only filled, high-chroma controls on screen.
5. **Depth is a hairline, not a shadow.** Cards read as paper via a 0.5pt border + a near-invisible 1.5pt shadow. Avoid material blur or strong elevation inside the content area.
6. **Dividers are inset and start under the text**, aligned to the title axis (14pt) — not full-bleed, never under the avatars.
7. **Type weights are restrained:** bold only on the greeting (32pt) and soon-row title; everything else is medium/regular. Countdowns carry emphasis through *color*, not size.

---

## 6. Quick reference

**Type scale** — 32 bold (greeting) · 16 semibold (soon title) · 15 regular (date) · 14.5 medium (row titles) · 12.5 (meta/secondary) · 11.5 semibold uppercase (group labels) · 11 (chips/Meet).

**Radii** — window content card 12 · row card 12 · buttons/search/chips 7–8 · Meet chip 6 · avatars full circle.

**Spacing** — column max-width 800, centered · 24/32 page padding · soon-row 18 padding · standard row 11/14 · group label→card 9 · card→next label ~26–34.

**SF Symbols used** — `house`, `gearshape`, `magnifyingglass`, `sidebar.left`, `calendar`, `clock`, `circle.fill`, `video.fill`, `chevron.right`, `record.circle` / `largecircle.fill.circle`, `record.circle.fill` (toolbar). Substitute the closest current symbol where exact names differ; keep 1.5-weight, rounded look.
