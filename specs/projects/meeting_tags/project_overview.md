---
status: complete
---

# Meeting Tags

Add user-applied **tags** to meetings: lightweight, colour-coded labels for past
meetings, fast to scan. Two surfaces are in scope for V1 — the **meeting detail
pane** and the **meeting list** (middle pane). Tags also become a searchable
meeting field (search *chrome* is not being redesigned — only the indexing).

## Source of the design

The design below was produced by a "design agent" that did **not** have access
to the codebase and worked from earlier comps. It captures the visual intent and
the product spirit, but specific token names, fonts, and colour helpers may be
*drift* rather than prescriptive. Where the notes conflict with the real design
system in code, the codebase wins and we reconcile during speccing. Notable
drift already identified:

- Tokens `label`/`label2`/`label3` → real tokens `ink`/`inkSecondary`/`inkTertiary`.
- `accent` / sage `#4E7D5C` → real token `sage`.
- `Color(hex: 0x1A1813)` (UInt form) → the repo's `Color(hex:)` takes a `"RRGGBB"`
  string; tints like the pill fill should come from `.ink.opacity(...)`.
- "IBM Plex Mono" → the repo's monospace face is **JetBrains Mono** (`biscottiMono`).
- The repo's colour system is fully **adaptive (light/dark)** via `dynamicColor`,
  with a test forbidding `colorScheme` checks in views — so the fixed tag-dot hues
  need a dark-mode story.

---

## Design Spec (from the design agent — directional)

> User-applied labels for past meetings. Lightweight, colour-coded, fast to scan.
> Visual identity: **F · Sage + Pressroom** — warm ivory paper, sage accent,
> Newsreader serif title, mono for timestamps/kickers.
> Two surfaces in scope for V1: the **meeting detail pane** and the **meeting list**.
> (Tags are also a search field — see note at end — but search UI is out of scope for V1.)

### The tag atom

A tag is a **soft neutral pill carrying a single colour dot**. Colour lives in the
dot only — it never floods the pill — which keeps a row of tags calm against the
ivory paper and lets the eye scan by hue.

| Property | Detail pane | List row (compact) |
|---|---|---|
| Height | 22 | 17 |
| Padding (h) | 9 | 7 |
| Corner radius | 6 | 5 |
| Gap (dot→text) | 6 | 5 |
| Font | SF Pro 11.5 / .medium | SF Pro 10.5 / .medium |
| Dot | 7×7 circle | 6×6 circle |
| Background | neutral ink wash (~5.5%) | neutral ink wash (~5%) |
| Text colour | primary ink (never coloured) | primary ink |

- The pill text is **never** coloured — only the dot.
- On the detail pane, a tag shows a faint **✕** on hover (right side) to remove it.
  List-row pills are not removable.

### Tag colours

Each tag name maps to one muted hue (mid-saturation, similar lightness so no single
tag screams). Illustrative palette:

| Tag (example) | Dot hue |
|---|---|
| Customer | `#3E6DA8` (blue) |
| Sales | `#B5683E` (clay) |
| 1:1 | `#7A6AAE` (violet) |
| Internal | `#6B7B86` (slate) |
| Important | `#B23320` (red) |
| Design | `#2A8C7E` (teal) |
| Hiring | `#A8843A` (amber) |
| Roadmap | `#5E8C3A` (olive) |

- Hues are assigned on creation and stable thereafter. New user-created tags take
  the next hue from the palette (round-robin).
- **Reserve sage `#4E7D5C`** for the app accent — do not hand it to a tag.

### 1 · Meeting detail pane

Tags get **their own line directly under the meta row** (date · duration · source
pill), above the calendar info card. Applied tags render left-to-right in the order
added; the row always ends with an **Add affordance** (a dashed-outline ghost pill).
Clicking Add opens a **picker popover** anchored below: a search/create field, a
"TAGS" kicker, a list of catalogue tags (applied ones show a ✓, click toggles), and
a `＋ Create "<query>"` row when the query matches no existing tag.

### 2 · Meeting list (middle pane)

Each row gains a **third line** of compact pills beneath the when-line, hidden
entirely when a meeting has no tags. **Cap at 2 pills + a `+N` overflow count.**

### Behaviours & rules

- Tags are **per-meeting**, user-applied, persist on the meeting record. No nesting,
  no required tags.
- Removing a tag from a meeting does **not** delete the tag globally — it stays in
  the catalogue for other meetings.
- Adding the same tag twice is a no-op.
- Ordering within a row = order applied.

### Tags in search (V1 behaviour, UI out of scope)

Search itself is not redesigned for V1. The only requirement: **a tag is indexed
as a meeting field** alongside title / notes / transcript, so typing a tag name in
the existing search matches meetings carrying that tag. No special search chrome.
