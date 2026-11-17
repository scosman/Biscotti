---
status: complete
---

# Phase 3: Manual Validation

## Overview

Write the manual validation script (`manual_validation.md`) that covers functional spec section 11. The user runs it on macOS 26 and macOS 15 with Obsidian, Bear, and Apple Notes installed. Findings feed back into the spec and drive small fixes if needed.

## Steps

1. Write `specs/projects/obsidian_bear_export/manual_validation.md` with numbered, reproducible test steps covering:
   - Obsidian: vault routing, `name=` placement, duplicate names, frontmatter tags/attendees
   - Bear: H1 title extraction, `tags=` sanitization, comma separators
   - Apple Notes: import dialog, cancel behaviour, note placement, markdown fidelity (macOS 26), plain-text fallback (macOS 15), title source
   - Cross-destination: first send, repeat-click unchanged, repeat after edit, cancel Notes import then re-click, no-tags meeting, unicode title, same-title same-day, nothing-to-send disabled, uninstalled app hidden
   - Size fallback: clipboard for >500 KB URL (padded test meeting)
2. Return as roadblock so the user can run the script on real hardware.
3. (After user returns findings) Write findings back into functional spec sections 8, 11, 12. Apply small code fixes if needed.

## Tests

- No new automated tests in this phase. The manual validation itself is the deliverable.
