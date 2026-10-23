---
status: complete
---

# Implementation Plan: Send meeting notes to Obsidian, Bear and Apple Notes

## Phases

- [x] Phase 1: The data model + pure logic. Covers `ExportDestination`/`SentExport` + `Meeting.sentExports` + the store API + `MeetingDetailData.sentExports`, and all of `ImportExport/SendTo/` (architecture §3), with their unit tests.
- [x] Phase 2: Sending + UI. Covers `SendEnvironment` + `AppCore+SendTo` (with the detection timing check and the caching decision recorded in functional spec §8), `ExportIcons`, `SendToButton` in the tab bar, the `…` → Send to submenu, the alerts, and the VM/AppCore/DesignSystem tests.
- [x] Phase 3: Manual validation. Write `manual_validation.md` (functional spec §11). The user runs it on macOS 26 and macOS 15. Write the findings back into the spec and fix small issues.
