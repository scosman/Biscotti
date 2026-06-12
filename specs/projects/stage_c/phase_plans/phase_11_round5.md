---
status: complete
---

# Phase 11 — Round 5 (Home screen redesign)

> **Status:** complete. Single item (H1) — the homepage was redesigned to feel
> native and cohesive — landed in one commit (coding → green `precommit_checks` →
> spec-aware CR → commit; `make ci` green, 704 BiscottiKit tests). Reviewer
> verdict CLEAN (no required changes). Design decisions recorded in
> `review_for_human.md` for the next hardware pass to react to visually.
>
> Continues `phase_11_round4.md` (P1).

---

## H1 — Redesign the Home screen (native, cohesive)

User feedback (verbatim intent): "The homepage is just awful. Zero effort design.
Redesign it. Still use native controls, but work on sizing/layout/spacing/
usability/look." Specific asks:
- Record button is ugly, floats in the middle, doesn't look like a button →
  make it a real, prominent **"Start Recording"** button.
- Whitespace is wild (content is vertically centered with big Spacers).
- Upcoming section is tiny despite the page being dedicated to record + upcoming +
  recent → larger, more detail, better design.
- **Missing "Recent Meetings"** section → add one listing the **last 4** meetings.
- Title is tiny → make it **"Biscotti"** (drop "Welcome to"); subtitle is super
  tiny → make it readable.
- Cohesion: same design language across elements, aligned widths, native feel.

### Design decisions (made during implementation; documented for the next
### hardware pass in `review_for_human.md` — react there, no blocking)
- **Layout:** drop the centering `Spacer()`s; top-anchored `ScrollView` with a
  single `maxWidth` content column (~600 pt) so all sections share one aligned
  width and the small-window (640×400) case scrolls instead of crushing.
- **Header:** `Text("Biscotti")` large/bold title + a readable secondary subtitle
  (no "Welcome to"). Left-aligned, consistent with native macOS.
- **Start Recording:** a NEW prominent DesignSystem button (bordered-prominent,
  `.controlSize(.large)`, red tint, record-dot icon, label "Start Recording").
  Added as a *new* component so the existing compact `RecordButton` (used by the
  sidebar + EventPreview) is untouched. Disabled while a recording is already
  running (`runState != .idle`).
- **Upcoming:** header + up to **5** events (was 3; matches the sidebar cap),
  richer two-line rows (time + relative countdown + platform badge) in a cohesive
  grouped/card container. Connect-calendar and no-upcoming empty states kept but
  restyled to match.
- **Recent Meetings (new):** header + last **4** from `core.summaries`, row =
  title + "date · duration" second line (identical formatting to the sidebar),
  tap → `core.select(id)` → `.meeting`. Empty state when there are no recordings.
- **Cohesion:** built entirely from `Tokens` (spacing/typography/colors) and
  shared `TimeFormatting`; sections share one card style + aligned width.

### Change set
- [ ] `DesignSystem`: add a prominent **StartRecordingButton** component
  (leave `RecordButton` unchanged). Optionally a small shared meeting-row
  second-line formatter in `TimeFormatting` so Home and the sidebar stay
  byte-identical (refactor `MeetingListViewModel.secondLineText` to delegate,
  keeping its tests green) — only if it reduces duplication cleanly.
- [ ] `HomeViewModel`: add `recentMeetings` (`core.summaries.prefix(4)`), a
  `selectMeeting(_:)` action (`core.select`), bump `upcomingPreview` cap 3 → 5,
  and recent/upcoming empty-state flags.
- [ ] `HomeView`: full redesign per the decisions above — native SwiftUI only,
  Tokens-driven, aligned widths, scrollable, prominent CTA, Upcoming + Recent
  sections. Update the SwiftUI preview to exercise populated + empty states.
- [ ] Tests (`HomeUITests`): recentMeetings returns ≤4 newest (order preserved);
  empty-recents flag; `selectMeeting` routes to `.meeting(id)`; update the
  upcoming-cap test (3 → 5). Keep all existing Home tests green.
- [ ] Append the design-decision note to `review_for_human.md`.
