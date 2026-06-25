---
status: complete
---

# Implementation Plan: Meeting Tags

Ordered by dependency: data first, then display, then editing, then a list restyle, then a
human visual pass. Each phase is one coherent CR. See `functional_spec.md`, `ui_design.md`, and
`architecture.md` for detail — this is just the build order.

## Phases

- [x] **Phase 1 — Data layer & search.** `Tag` `@Model` + `Meeting.tags` relationship +
  schema registration; `TagData` DTO; DataStore tag API (`allTags`, `createTag` with
  round-robin slot + case-insensitive dedup, `applyTag`, `removeTag`, `createTagAndApply`);
  `tags` added to `MeetingSummary` / `MeetingDetailData` (alphabetical); search indexing
  (`SearchField.tags`, weight 3 in `scoreMeeting`, `fieldSortOrder`, `matchedFieldsText`).
  Full data-layer + search tests. No UI. (architecture §1–3, §8)

- [x] **Phase 2 — Display primitives & list.** Adaptive 8-swatch tag palette in
  `Color+Theme.swift`; `TagPill` (`.detail` / `.compact`); minimal `Layout`-based
  `FlowLayout`; render the compact third line (first 3 + `+N`) in `MeetingListView.meetingRow`.
  Read-only display path, end to end. (architecture §4.1–4.3, §5 list)

- [x] **Phase 3 — Detail-pane editing.** `TagAddButton` (three states); `TagPickerPopover`
  + pure `computeTagPickerResult` (tested) with keyboard nav; wire `MeetingDetailViewModel`
  (load catalogue, `toggleTag` / `createAndApply` / `removeTag`, refresh + `reloadSummaries`);
  insert the wrapping tags row into `MeetingDetailView.chrome`. (architecture §4.4–4.5, §5 detail)

- [x] **Phase 4 — Past Meetings list restyle (styling only).** Repaint the middle-pane
  meeting list to the Sage + Pressroom identity — **no behaviour/feature changes** (same
  rows, sort, search, selection model, multi-select, ⌫-delete, keyboard nav). Keep the
  native `List(selection:)`; **try a native SwiftUI re-skin first** — `.tint(.sage)` to kill
  the system-blue selection and `.scrollContentBackground(.hidden)` so the ivory `paper`
  shows. The implementer **web-searches to confirm the current best macOS-15 approach**
  before coding. Restyle per ui_design §10: warm ivory pane, hairline list↔detail border,
  sage selection (wash + inset-ring *intent*; native `.tint` is the first cut),
  selected-row when-line → sage, mono when-line (`.monoMeta`) + mono uppercase group headers
  (`.kicker()`), SF Pro title, **no serif**, tag pills unchanged (neutral fill + coloured
  dots, cap 3 + `+N`). Dark mode = pure token swap. **If native isn't good enough, stop and
  escalate** (next step: AppKit `selectionHighlightStyle = .none` + `.listRowBackground`
  wash). **Human visual review before CR** (per process this phase). (ui_design §10)

- [x] **Phase 5 — Visual review & tweaking (human interactive).** The only fully
  human-driven phase. Run the app; review the detail tags row, the list third line, the
  picker, and the Phase-4 list restyle in **light and dark**; finalize the 8 dark dot
  variants on real hardware; tune pill spacing, sizes, the hover-✕, and the Add-affordance
  states. Apply tweaks discovered in review.
