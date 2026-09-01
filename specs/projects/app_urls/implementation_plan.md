---
status: complete
---

# Implementation Plan: App URLs

Three phases. Phase 1 is pure and fully unit-testable with no app wiring;
Phase 2 makes the URLs actually work; Phase 3 adds the consumer, the docs,
and the on-hardware proof.

## Phases

- [x] **Phase 1 — `AppLinks` module.** New dependency-free target
  (`AppLink`, `MeetingTarget`, `MeetingTab`), the parser, the builder, and
  `AppLinksTests` covering the whole vocabulary, both failure tiers, and the
  build→parse round-trip. Wired into `Package.swift` for `AppCore`,
  `MCPServer` and `MeetingDetailUI`. Nothing calls it yet — architecture §2.

- [x] **Phase 2 — Make the links work.** `AppCore.apply(_:)` plus
  `MeetingOpenIntent` (replacing `TranscriptJump`), `AppLinkError` and the
  shell alert, `startRecording(title:)`, the `MeetingDetailUI` tab mapping,
  and the move from `onOpenURL` to `application(_:open:)` with the
  cold-launch pending slot. Rewrites `DeepLinkTests`. Architecture §3–§5.

- [x] **Phase 3 — Producers, docs, manual test.** The `app_url` field on
  `biscotti_get_meeting` (+ schema and fixture updates), the **Copy Meeting
  Link** command in the list context menu and detail overflow menu,
  `App/deeplinks.md`, and the `app_urls` ManualTestKit script with its
  `WiredScripts` pasteboard wiring. Marks `mcp_*` manual steps `not-run` per
  the staleness rule. Architecture §6–§9.

## Notes

Phase 2 is the largest and the only one that changes existing behavior
(`biscotti://meeting/{uuid}` without `time` stops being a no-op; `onOpenURL`
is removed). It is kept whole rather than split because the delegate change
and the `AppCore` entry point are meaningless apart — splitting them would
land a phase where URLs parse but nothing routes.

The manual script in Phase 3 is the only proof that cold-launch and
menu-bar-only delivery work; the app target has no test host. It requires a
human on real hardware and will hold `make manual-tests-check` red until run.
Copy Meeting Link must land before the script in the same phase — the script
reads the link it produces off the pasteboard.

Neither `make precommit-checks` nor any Swift build runs in a Linux agent
container (the pinned SwiftLint/SwiftFormat binaries are macOS-only, and
compiling Swift is blocked besides). Every phase therefore needs its gating
checks run on a Mac before commit.
