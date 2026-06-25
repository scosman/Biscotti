---
status: complete
---

# Functional Spec: Meeting Tags

User-applied, colour-coded labels for meetings. Lightweight, fast to scan, and
searchable. V1 surfaces: the **meeting detail pane**, the **meeting list** (middle
pane), and the **existing search** (indexing only — no new search chrome).

---

## 1 · Concepts

- **Tag** — a named, colour-coded label that lives in a global **catalogue**. A tag
  exists independently of any meeting; the same tag can be applied to many meetings.
- **Application** — the link between a tag and a meeting. A meeting has zero or more
  tags; a tag is applied to zero or more meetings. (Many-to-many.)
- **Catalogue** — the set of all tags that exist. Tags enter the catalogue by being
  created; in V1 they never leave it (see §3).

A tag carries exactly two pieces of user-visible state: its **name** and its
**colour**. There is no description, no nesting, no required tags, no per-meeting
ordering metadata.

---

## 2 · Tag colours

- A fixed palette of **8 swatches** (mid-saturation, similar lightness, harmonising
  with the ivory/sage system). Sage (the app accent) is **reserved** and never a tag
  colour. The illustrative hues from the design (blue, clay, violet, slate, red,
  teal, amber, olive) are the starting palette.
- Each swatch is defined as an **adaptive colour** (light + hand-tuned dark variant)
  so dots stay legible on both the ivory and near-black papers. Views never branch on
  `colorScheme` (repo rule); the swatch resolves itself.
- **Assignment:** when a tag is created it is given the **next swatch round-robin**
  by catalogue creation order (the Nth tag created → swatch `N mod 8`). The assignment
  is **stored on the tag and stable** thereafter. Beyond 8 tags, colours repeat — this
  is acceptable.
- In V1 the user cannot choose or change a tag's colour (see Out of Scope, §10).

---

## 3 · Tag lifecycle (V1 scope)

V1 supports exactly two catalogue operations, both initiated from the tag picker on
the detail pane:

1. **Create** a new tag (by typing a new name and confirming).
2. **Apply / un-apply** an existing tag to/from the current meeting.

Explicitly **not** in V1: global rename, recolour, or delete; a catalogue-management
screen; bulk tagging. Consequences the design must accept:

- Removing a tag from a meeting (detail ✕ or un-toggle in the picker) only removes the
  **application** — the tag remains in the catalogue for other meetings, even if it is
  now applied to none (**orphan tags persist**). There is no V1 affordance to delete an
  orphaned or misspelled tag. (A later project adds management.)
- Deleting a **meeting** removes its applications but never deletes the tags themselves.

---

## 4 · Naming & validation

- The name is the user's typed string with **leading/trailing whitespace trimmed**.
  Internal characters are preserved as typed (e.g. `1:1`, `Q3 Roadmap`).
- A name must be **non-empty** after trimming, or it cannot be created.
- **Uniqueness is case-insensitive.** Two tags may not differ only by case. If the
  user tries to create a name that case-insensitively equals an existing tag, the
  existing tag is **reused** (applied/toggled) rather than duplicated — so the "Create"
  affordance never appears for a name that already exists (§6).
- **Length cap:** names are capped at **40 characters** (input is limited at the field;
  longer paste is truncated). Keeps pills a sane width.

---

## 5 · Meeting detail pane

### 5.1 Tags row

- A dedicated **tags row** sits directly **under the meta line** (date · duration ·
  source pill) and **above** the calendar info card.
- It renders the meeting's applied tags as **detail-size pills** (a neutral pill with a
  single coloured dot; pill text is never coloured — only the dot), followed always by
  the **Add affordance** at the end.
- The row **wraps** to additional lines when tags overflow the available width; the Add
  affordance stays at the end of the flow.
- **Ordering:** tags render in a **deterministic alphabetical order** (case-insensitive,
  localised), *not* "order applied." Rationale: the underlying many-to-many relationship
  is unordered in SwiftData, so insertion order can't be relied on; alphabetical is
  stable and scannable. (Reconciliation note — see §11. If true order-applied is later
  wanted, it requires a join model with an order field.)

### 5.2 Removing a tag

- Each detail pill reveals a faint **✕** on hover (right side, fades 0→1). Clicking it
  removes that tag's application from this meeting immediately (no confirm). This follows
  the existing hover-to-remove pattern used by note rows.
- Removal is immediate and persisted; the list and detail refresh.

### 5.3 Add affordance (three states)

A ghost pill matching tag dimensions, whose treatment depends on context:

- **Meeting has tags** → compact "＋ Add tag" with a dashed neutral outline; hover adds a
  soft fill / darker border.
- **Meeting has no tags** → a more inviting "Add tags" in **sage** (sage outline + text)
  to encourage the first tag; hover adds a faint sage fill.
- **Picker open** → an active sage-tinted state (sage fill + sage border/text).

Clicking the affordance opens the picker popover (§6).

---

## 6 · Tag picker popover

Anchored below the Add affordance (follows the existing `SpeakerMappingSheet` /
`PersonPickerPopover` pattern). Contents top-to-bottom:

1. **Search / create field** — magnifying-glass icon + text input, placeholder
   "Add or create a tag…". Auto-focused on open. Filters the list live (case-insensitive
   **contains** match) as the user types.
2. **Kicker** "TAGS" (mono, uppercase).
3. **Catalogue list** — every catalogue tag (filtered by the query) as a row: colour dot
   + name. A tag **already applied** to the current meeting shows a trailing **sage ✓**.
   Clicking a row **toggles** the application on/off for the current meeting (immediate,
   persisted). List order is **alphabetical** (case-insensitive).
4. **Create row** — shown only when the trimmed query is non-empty **and** no catalogue
   tag equals it case-insensitively: `＋ Create "<query>"`. Clicking it creates the tag
   (next round-robin colour) **and applies it** to the current meeting in one step, then
   clears the query. Full sage fill on hover.

Behaviours:

- Toggling is **idempotent** — a tag already applied shows ✓ and clicking removes it;
  applying an already-applied tag never duplicates.
- The popover stays open across multiple toggles/creates so several tags can be managed
  in one session; it dismisses on outside click / escape (standard popover behaviour).
- An empty catalogue with an empty query shows just the field + kicker (and the create
  row appears as soon as the user types a name).

---

## 7 · Meeting list (middle pane)

- Each meeting row gains a **third line** beneath the existing when-line (date · duration),
  rendering **compact** tag pills.
- The third line is **hidden entirely** when a meeting has no tags (no reserved empty
  space — row height stays compact for untagged meetings).
- **Overflow cap:** show at most the **first 3** pills (alphabetical), then a mono **`+N`**
  count for the remainder (e.g. `● Customer  ● Design  ● Important  +1`). Keeps row height
  predictable in a dense list.
- Compact pills are **not removable** and not interactive — display only. Tag editing
  happens on the detail pane.
- **Selection legibility:** the selected row already uses the system's light sage selection
  wash (`accentWashStrong`), a tint rather than a solid fill — coloured tag dots remain
  legible on it. (No change needed; the spec only requires that dots stay readable on the
  selected background.)

---

## 8 · Search

The existing search (a custom toolbar field → debounced `searchHits` → ranked list) is
**not redesigned**. The only change is indexing:

- A meeting's **tag names** become a searchable field. Typing a tag name matches every
  meeting carrying that tag, exactly as typing matches a word in the title.
- **Weight: 3** — a tag match scores the **same as a title match** (the current top
  weight; title = 3, people = 2, transcript = 1, notes = 1). Rationale: a tag is an
  explicit, deliberate user label, so a tag-name query should surface tagged meetings as
  strongly as a title hit. Per matching term, if any of the meeting's tag names contain
  the term, add 3 and record a `.tags` matched-field.
- The search-result row's "matches: …" label gains a **"tags"** entry when the tag field
  matched, alongside title / people / transcript / notes.
- No new search chrome: no tokens, filter bar, or tag-specific UI in V1.

---

## 9 · Edge cases

- **Duplicate create** (case-insensitive match to existing) → reuse/toggle the existing
  tag; no duplicate row; create row not shown.
- **Whitespace-only query** → no create row; no-op.
- **Rapid toggling** of the same tag → idempotent end state (applied or not).
- **Tag applied to many meetings, removed from one** → other meetings keep it.
- **Orphan tag** (applied to no meetings) → remains in the catalogue and the picker list;
  no V1 way to delete it.
- **>8 tags** → palette colours repeat round-robin; no error.
- **Meeting deleted** → its applications drop; the tags persist.
- **Long name** → capped at 40 chars on input; compact list pills truncate with tail
  ellipsis and single line; detail pills show the full (capped) name on one line.
- **Many tags on one meeting** → detail row wraps to multiple lines; list shows first 3 +
  `+N`.

---

## 10 · Out of scope (V1)

- Global tag **rename**, **recolour**, or **delete**; any catalogue-management surface.
- User **choosing** a tag's colour (auto round-robin only).
- True **order-applied** ordering (alphabetical instead — §5.1).
- Tag **search chrome**: tokens, filter bars, tag-scoped search modes.
- Tagging **upcoming**/calendar events that have no meeting record; **bulk** tagging from
  the list; **nested** or **required** tags; smart/auto-suggested tags.

---

## 11 · Reconciliations with the design notes

The design agent had no codebase access; these points reconcile its notes to the repo:

- **Tokens:** `label/label2/label3 → ink/inkSecondary/inkTertiary`; `accent`/sage `#4E7D5C`
  → `sage`. Pill fill comes from `.ink.opacity(~0.05)` (a `neutralChip`-style wash), not a
  literal `Color(hex: 0x…)`.
- **Mono font** is **JetBrains Mono** (`biscottiMono` / `.monoBadge` for `+N`), not IBM Plex
  Mono.
- **Colour adaptivity:** dot hues are defined as adaptive `dynamicColor` pairs (the repo
  forbids `colorScheme` checks in views and tests for it), so each hue needs a tuned dark
  variant. A human eyeballs the dark variants on hardware (as the dark-mode project did).
- **Ordering** is alphabetical, not order-applied (§5.1) — the only behavioural deviation
  from the notes, driven by SwiftData's unordered relationships.

---

## 12 · Constraints

- **Adaptive colour discipline:** all new colours via `dynamicColor(light:dark:)`; no
  `colorScheme` branching in views (enforced by an existing test).
- **Performance:** search remains an in-memory full-table scan; adding a tag-name check per
  meeting is negligible at V1 scale. List summaries include each meeting's tags — a cheap
  relationship read on the data actor.
- **Persistence:** adding a `Tag` entity + a many-to-many relationship with an empty-array
  default is **additive**; SwiftData handles it without a schema migration (no V2 needed).
- **Apple-silicon, macOS 15+**, SwiftUI + Swift Observation, package-first (logic in
  `BiscottiKit`, testable via `swift test`).
