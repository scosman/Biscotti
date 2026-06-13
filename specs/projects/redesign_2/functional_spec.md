---
status: complete
---

# Functional Spec: redesign_2 — Design Project 1 (App Container + Home)

## 1. Purpose & scope

A **design-polish pass** on two surfaces only: the **app container** (window
chrome colors) and the **Home screen**. The app is already functional and
"SwiftUI native"; the goal is more *style* — using the mechanisms Apple
provides (tint, background colors, materials, composed native controls), **not**
custom rendering or custom controls.

The agent-authored visual spec lives in [`agent_spec.md`](agent_spec.md). That
document is the **visual source of truth** for Home (type scale, spacing,
radii, palette). This functional spec resolves *behavior*, *data*, and the
points where `agent_spec.md`, the existing code, and "what Apple would do"
conflict — and records the decisions made during speccing.

### In scope
- App-container **background colors** for the Home/detail surface.
- A full rebuild of the **Home screen** to match `agent_spec.md` §4.
- A shared **avatar** component (initials + deterministic color).
- A small, **read-only** extension to the Home read-model so past-meeting rows
  can show participants.

### Out of scope (do not touch)
- The Past Meetings list/detail (the three-pane reader) and any meeting-detail
  view — `agent_spec.md` is explicit, and so is the project overview.
- **Sidebar** structure/behavior and the **top app-bar** (search field, Home
  button, **Record button**). The overview states the container is "better in
  code than spec"; we take only background colors from the spec here. See §3.
- Any write-path / data-entry changes. The read-model extension in §7 is
  read-only.
- Dark mode (the app is light-appearance only).

---

## 2. Resolved decisions (speccing Q&A)

These override `agent_spec.md` where they differ. Recorded so the build agent
follows them, not the raw spec.

1. **Container scope = background colors only.** Adopt the `#FBFBFC` detail-pane
   background and the palette tokens (text tiers, hairline separator, neutral
   chip fill, accent-wash) **for use inside Home**. **Leave the sidebar rows,
   the toolbar Record button, the search field, and sidebar section labels
   exactly as they are in code.** `agent_spec.md` §3's sidebar/top-bar restyle
   is **not** applied. (The sidebar already uses an accent-wash selection and
   the Record button was just redesigned.)

2. **Greeting has no name.** Render time-of-day only — "Good morning" /
   "Good afternoon" / "Good evening" — chosen from the local clock. The
   `{name}` token in `agent_spec.md` §4.1 is dropped (no user-name data exists,
   and we are not adding a profile concept).

3. **Avatars use a deterministic email-hash color + 2-letter initials**, not the
   first-initial gradient table in `agent_spec.md` §1. See §6. This applies to
   **all** avatars (upcoming and past).

4. **Past rows show participants via a read-only read-model extension.** The
   Home read-model (`MeetingSummary`) is extended to carry participant
   name+email for avatars/initials. See §7. (Past meetings already store
   participants in the DB; this only surfaces them.)

5. **The "starting soon" hero row reuses the existing join logic.** The first
   Upcoming row becomes the hero **only** when the meeting is within the
   existing ±15-minute join window (`EventPreviewViewModel.joinWindowSeconds`),
   and offers "Join & Record" (opens the conference URL **and** starts a
   pre-associated recording) plus a "View in calendar" link. Otherwise it
   renders as an ordinary Upcoming row. See §5.4.

---

## 3. App container (background colors only)

- The **detail pane** behind Home is filled with the **content background**
  `#FBFBFC` (a near-white, faintly cool custom `Color`) so the stock
  window-background grey does not show through. Implemented as a full-bleed
  color behind Home's content (or an equivalent container background) — scoped
  to the Home/detail surface, not the sidebar.
- The new palette is added as **reusable design tokens** (see §6) so Home and
  future surfaces share one source of truth: content background, card fill
  (white), the three text tiers, hairline separator, neutral chip fill, the
  accent wash, and the "live/success" green.
- **Accent stays stock systemBlue** (`#007AFF`) — we do not introduce a custom
  blue. The window/app `.tint()` already resolves to system accent; Home uses
  `Color.accentColor` for accent elements.
- **No other container changes.** Sidebar material, sidebar rows, section
  labels, the Home/Settings/Past nav rows, the toolbar (search + Record) are
  untouched.

> HIG note: a near-white content surface with white cards + hairline borders is
> a deliberate, spec-driven departure from stock `windowBackgroundColor` grey.
> It is composed from native primitives (Color + RoundedRectangle + stroke +
> a whisper shadow), so it stays within "use Apple's mechanisms."

---

## 4. Home screen — layout & behavior

Home is rebuilt top-to-bottom as: **greeting block → stat chips → "Upcoming"
card → "Past Meetings" card**, inside a single centered column.

### Layout
- A `ScrollView` containing one left-aligned `VStack` constrained to
  **`maxWidth: 800`** and centered horizontally.
- **Vertically centered when short:** when content is shorter than the
  viewport, the column sits centered (calm welcome). When content exceeds the
  viewport, it scrolls normally.
- Page padding **24 top/bottom, 32 leading/trailing**; section rhythm per
  `agent_spec.md` §2 (group label → card → ~26–34 gap).
- Exact type/spacing/radii values: follow `agent_spec.md` §4 and §6.

---

## 5. Home sections (behavior + data)

### 5.1 Greeting block
- Line 1: time-of-day greeting (see decision §2.2), 32pt bold.
- Line 2: today's date, e.g. "Wednesday, June 12", 15pt regular secondary.
- The greeting and date recompute as the day/`minuteTick` advances (no manual
  refresh).

### 5.2 Stat chips (at-a-glance row)
A horizontal row of up to three neutral pill chips (one reusable
`StatChip(icon:tint:text:)`), each derived live from calendar data:

| Chip | Icon (tint) | Text | Derivation |
|---|---|---|---|
| Meetings left | `calendar` (accent) | "{N} meetings left today" | Count of today's meeting-like events that are still upcoming/in-progress (the in-memory upcoming set, starting on the local **today**). |
| Scheduled time | `clock` (secondary) | "{H}h {M}m scheduled" | Sum of durations (`end−start`) of those same remaining-today events. |
| Next in | `circle.fill` (green) | "Next in {…}" | Countdown to the soonest **future** upcoming event (`displayedUpcoming` first item), using `minuteTick`. |

Behavior:
- **No calendar access:** the entire chip row is hidden (the "connect calendar"
  affordance lives in the Upcoming card, §5.5).
- **Authorized but nothing today / nothing upcoming:** omit only the chips that
  have no data (e.g. drop "Next in" when nothing is upcoming; "0 meetings
  today" / "0h 0m scheduled" still render when authorized).
- Counts refresh on `minuteTick` and on calendar reloads.

> The chips reflect what's **left today** — they derive from the in-memory
> upcoming set, so meetings that have already ended earlier today are not
> counted. (Whole-day totals would need a separate calendar day-query, out of
> scope for this pass.)

### 5.3 Upcoming card
- Group label **"UPCOMING"** (11.5pt semibold, uppercase, secondary).
- One white card (radius 12, hairline + whisper shadow) containing the upcoming
  rows, composed manually (**not** a `List`), with inset hairline dividers
  (14pt leading inset, under the text not the avatars). First row has no top
  divider.
- Source: `core.displayedUpcoming` (ended events already filtered), capped at a
  small preview count (keep the current cap of **6**).
- Each row starts with the **fixed 78pt avatar column** (§6) so all titles
  align regardless of participant count.
- **Row tap** selects the event → existing `EventPreview` detail
  (`selectEvent`), unchanged.

### 5.4 "Starting soon" hero row (first upcoming row, conditional)
The first Upcoming row is promoted to a **hero** *only when* the meeting is
within the join window (`|secondsUntilStart| ≤ 15min`, matching
`EventPreviewViewModel`). Otherwise it is an ordinary Upcoming row (§5.6).

When hero:
- Row background = **accent @ 6%** wash; larger padding (18); 28pt avatars.
- Center stack: title (16pt semibold) + truncating participant names; meta line
  with **countdown in accent semibold** · time · **Meet chip** (§5.7);
  optional description line from `event.notes` (single-line, truncating; omitted
  if empty).
- **Trailing action stack** (replaces the chevron):
  - **"Join & Record"** — filled accent button (custom `ButtonStyle`, not raw
    `.borderedProminent`). Action = the existing **`joinAndRecord`**: open the
    conference URL **and** start a recording pre-associated with this event.
    - If the event has **no conference URL**, the button reads **"Record"** and
      just starts the pre-associated recording (mirrors
      `EventPreviewViewModel.primaryAction == .record`).
  - **"View in calendar"** — quiet text link. Opens **Calendar.app at the
    event's start date** (live `CalendarEvent` has no EK identifier, so we use
    the date-based fallback already implemented for "open in calendar").
- **Recording already in progress:** "Join & Record" is **disabled** (matches
  `EventPreviewViewModel.recordDisabled`), so we never start a second recording.
- **Chevrons vs buttons rule** (`agent_spec.md` §5.2): the hero shows buttons
  and **no** chevron; all other rows show a chevron and no buttons.

### 5.5 Upcoming empty / permission states (kept, restyled)
Preserve current behavior, re-skinned into the new card:
- **No calendar access** → card with "Connect your calendar…" + an "Allow
  Calendar Access" button (`requestCalendarAccess`).
- **Authorized, nothing upcoming** → card with "No meetings coming up".

### 5.6 Ordinary upcoming rows (non-hero)
- 26pt avatars; title 14.5pt medium; meta line = **countdown (accent medium)** ·
  time · Meet chip.
- **Trailing: `chevron.right` only** (tertiary). No Join button.

### 5.7 Past Meetings card
- Group label **"PAST MEETINGS"** with a trailing **"See all ›"** link on the
  same baseline (accent, 12.5pt + small chevron). The link → `showMeetings()`.
  (This replaces the current in-card "See all" row.)
- One white card; rows composed manually with inset dividers.
- Source: `core.summaries` preview (keep the current cap of **4**).
- Each past row: **avatar column** (from the extended read-model, §7) + title
  (14.5pt medium) + meta `"Today · 32m · {names}"` (existing
  `TimeFormatting.meetingSecondLine` for the "Today · 32m" part, with the
  participant names appended). **Trailing: `chevron.right`** (tertiary).
  - **No participants** (older meetings, or none captured): avatar column shows
    a neutral fallback avatar; the "· {names}" tail is omitted.
- **No recordings yet** → card with "No recordings yet".
- Row tap selects the meeting (`selectMeeting`), unchanged.

### 5.8 Meet chip (reusable)
Inline capsule: `video.fill` (green `#1A9D5A`) + the platform label
(`event.conferencePlatform`, e.g. "Google Meet"). Rendered only when a platform
is known. Per `agent_spec.md` §4.9.

---

## 6. Shared components & tokens

### 6.1 Avatar (new shared component)
A reusable `Avatar` (and a stacked `AvatarCluster` for the 78pt column):

- **Initials:** two letters — first letter of the first name + first letter of
  the last name, uppercased (e.g. "Sam Altman" → "SA"). Fallbacks: a
  single-word name → its first two letters; empty/unknown → a neutral glyph
  (e.g. `person.fill`) or "?".
- **Color:** deterministic. Hash the person's **email** (lowercased, trimmed);
  if no email, hash the display name. `abs(hash) % 16` indexes a fixed
  **16-color palette**, so the same person always gets the same color and
  collisions are rare. Rendered as a circle filled with that color (a subtle
  135° lighter→darker gradient of the chosen hue is acceptable for the spec's
  "colorful, never grey" intent); initials in white `.semibold`; inset hairline
  ring; **+2pt white outer ring on stacked instances** so overlaps read.
- **Cluster:** up to **3** overlapped avatars (overlap ≈ 66% of size, negative
  leading), then a **"+N"** neutral badge for the remainder. People list =
  organizer (if any) + attendees, de-duplicated by email; "+N" counts the rest.
  Pinned to a fixed **78pt** leading-aligned frame. Avatar size 28pt on the
  hero, 26pt elsewhere.
- The hash must be **stable across launches** (don't use Swift's
  randomized `Hasher`; use a fixed string hash, e.g. FNV-1a / a simple
  deterministic fold).

### 6.2 Design tokens
Extend `DesignSystem/Tokens` with the new palette + the few new type/radii
values Home needs (content background, card fill, text tiers, hairline,
neutral chip fill, accent-wash opacities, success green, plus the 16-color
avatar palette). Reuse existing tokens where they already match.

### 6.3 Other reusable views
`StatChip(icon:tint:text:)`, the Meet chip, and the Join-&-Record `ButtonStyle`
are small reusable views (placement decided in architecture).

---

## 7. Data-layer change (read-only)

Extend the Home read-model so past rows can show participants:

- `MeetingSummary` gains a lightweight, ordered **participants** list (display
  name + optional email) — enough for initials and the deterministic color.
- `DataStore.meetingSummaries(...)` maps `meeting.participants` (and/or
  organizer) into that list. Keep it cheap (cap the number mapped, e.g. first
  few, since only ~3 avatars + "+N" render).
- **Read-only:** no schema change, no write path, no migration — `participants`
  already exists on the `Meeting` model.
- **Manual-test staleness:** this does not touch `Packages/Transcription` or
  `Packages/AudioCapture`, so the manual-test results gate is unaffected.

Upcoming rows already have participant data on `CalendarEvent`
(`organizer` + `attendees`); no change needed there.

---

## 8. Constraints & non-goals

- **Native/HIG, composed primitives only.** No custom drawing, no third-party
  controls. Custom `ButtonStyle`/`Color`/gradients/`RoundedRectangle` are fine
  (they are Apple mechanisms); a hand-rolled rendering pipeline is not.
- **Light appearance only.**
- **No behavior regressions:** navigation (tap → EventPreview / MeetingDetail),
  calendar permission flow, recording start, and search all behave as today.
- **Accent discipline** (`agent_spec.md` §5.3): blue only on the live
  countdown, the primary action, links, and the (untouched) nav selection.
- **One saturated element per region:** the toolbar Record button (red, in
  code, untouched) and the hero "Join & Record" (blue) are the only filled
  high-chroma controls.

---

## 9. Defaults to confirm at review

Sensible defaults chosen without a blocking question; flag any to change:
1. **Stat-chip semantics** (§5.2): chips show what's **left today** (derived
   from the in-memory upcoming set; already-ended meetings not counted).
2. **Preview caps unchanged:** Upcoming 6, Past 4.
3. **Avatar rendering:** flat 16-color palette rendered as a subtle gradient;
   initials white semibold. (Pure-flat fill is the alternative.)
4. **"View in calendar"** for the hero opens Calendar.app at the event date
   (no EK identifier exists for live events).
5. **Empty/permission states** kept (behavior unchanged), re-skinned into the
   new cards.
