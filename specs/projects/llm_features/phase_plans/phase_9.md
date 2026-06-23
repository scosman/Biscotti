---
status: complete
---

# Phase 9: Settings Polish — Header Caption + Section Order

## Overview

Implements `functional_spec.md` section 13.3 and `ui_design.md` section 7.3: (1) moves the "AI runs locally on your Mac." text from the AI Enhancements section footer to muted secondary text trailing the section header, and (2) reorders `SettingsView`'s `Form` sections so Permissions is 2nd (after General): General, Permissions, AI Enhancements, Notifications, Calendars, Debug.

## Steps

1. **SettingsView.swift — reorder sections in `body`:** Change the Form to: `generalSection`, `permissionsSection`, `aiEnhancementsSection`, `notificationsSection`, `calendarSection`, `debugSection`. Update/remove the stale comments.

2. **SettingsView.swift — move footer to header caption in `aiEnhancementsSection`:** Replace the `Section { ... } header: { ... } footer: { ... }` with a custom header row: `HStack { Text("AI Enhancements"); Spacer(); Text("AI runs locally on your Mac.").font(Tokens.metadataFont).foregroundStyle(Tokens.secondaryText) }`. Remove the `footer:` clause entirely.

3. **SettingsView.swift — extract section order as a testable constant:** Add a `static let sectionTitles` on the view (or a module-level constant) listing the canonical order: `["General", "Permissions", "AI Enhancements", "Notifications", "Calendars"]` (plus "Debug" in DEBUG). This lets tests assert the intended order without parsing the view hierarchy.

4. **SettingsUITests — add section-order and header-caption tests:** A new test file `SettingsLayoutTests.swift` with tests for: (a) `sectionTitles` matches the expected order, (b) `aiEnhancementsHeaderCaption` constant equals the expected string.

## Tests

- `sectionOrderMatchesSpec`: asserts the `SettingsView.sectionTitles` array matches the expected order.
- `aiEnhancementsHeaderCaptionPresent`: asserts `SettingsView.aiEnhancementsHeaderCaption` equals "AI runs locally on your Mac."
