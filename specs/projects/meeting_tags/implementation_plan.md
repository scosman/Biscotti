---
status: complete
---

# Implementation Plan: Meeting Tags

Ordered by dependency: data first, then display, then editing, then a human visual pass.
Each phase is one coherent CR. See `functional_spec.md`, `ui_design.md`, and
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
  `FlowLayout`; render the compact third line (first 2 + `+N`) in `MeetingListView.meetingRow`.
  Read-only display path, end to end. (architecture §4.1–4.3, §5 list)

- [ ] **Phase 3 — Detail-pane editing.** `TagAddButton` (three states); `TagPickerPopover`
  + pure `computeTagPickerResult` (tested) with keyboard nav; wire `MeetingDetailViewModel`
  (load catalogue, `toggleTag` / `createAndApply` / `removeTag`, refresh + `reloadSummaries`);
  insert the wrapping tags row into `MeetingDetailView.chrome`. (architecture §4.4–4.5, §5 detail)

- [ ] **Phase 4 — Visual review & tweaking (human interactive).** The only human-driven
  phase. Run the app; review the detail tags row, the list third line, and the picker in
  **light and dark**; finalize the 8 dark dot variants on real hardware; tune pill spacing,
  sizes, the hover-✕, and the Add-affordance states. Apply tweaks discovered in review.
