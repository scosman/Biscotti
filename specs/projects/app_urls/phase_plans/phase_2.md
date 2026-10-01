---
status: complete
---

# Phase 2: Make the links work

## Overview

Wire the Phase 1 `AppLinks` vocabulary into the running app: `AppCore.apply(_:)`
replaces `handleDeepLink(_:)` with the full route table, `TranscriptJump`
becomes `MeetingOpenIntent` (with a monotonic token), missing targets surface
as `AppLinkError` + a shell alert, `startRecording` gains a `title:` thread,
`MeetingDetailUI` applies tab/seek intents, and URL delivery moves from
`Window.onOpenURL` to `AppDelegate.application(_:open:)` with a cold-launch
pending slot. Rewrites `DeepLinkTests`/`DeepLinkJumpTests` as behavior tests
against `apply(_:)`. Architecture §3–§5.

## Steps

1. **`Packages/BiscottiKit/Sources/AppCore/AppCore.swift`**
   - `import AppLinks`; delete `TranscriptJump`; add
     `MeetingOpenIntent { meetingID, target, token: UInt }` (public init),
     `pendingMeetingIntent` (+ private `meetingIntentToken` counter,
     incremented per intent so identical links stay distinct), and
     `consumeMeetingIntent()`.
   - Add `AppLinkError: String` enum (`meetingNotFound`, `eventNotFound`) with
     `title`/`message` copy from functional spec §9; `linkError` stored
     property (`public internal(set)`); `dismissLinkError()`.
   - Replace the deep-link extension with `apply(_ link: AppLink) async`:
     R6 onboarding guard → switch per architecture §3.2 table
     (`.meeting` → `store.meetingExists` else `linkError = .meetingNotFound`
     with route untouched; `.upcoming` → `calendar.event(forKey:)` else
     `.eventNotFound`; `.search` → `showMeetings()` + `setMeetingsQuery` +
     `focusSearch()`; `.record` → already-recording routes to `.recording`,
     else `await startRecording(title:)`). Debug logs for both failure tiers.
   - `startRecording(eventKey:title:)` with default `nil` for both params;
     add `pendingStartupTitle` (stashed for retry, cleared on
     stop/cancel/success); thread through
     `completeRecordingStartup(eventKey:title:generation:)` to
     `recording.start(title:)`.
2. **`Packages/BiscottiKit/Sources/Recording/RecordingController.swift`**
   - `start(title: String? = nil)`; `setupMeetingStorage(title:)` uses
     `title ?? Self.autoTitle()` at `store.createMeeting(title:)`.
3. **`Packages/BiscottiKit/Sources/MeetingDetailUI/MeetingDetailViewModel.swift`**
   - `import AppLinks`; `Tab` gains `init(_ tab: MeetingTab)`;
     `pendingJumpToken` → `pendingIntentToken: MeetingOpenIntent?`;
     `applyPendingJumpIfNeeded()` → `applyPendingIntentIfNeeded()`
     switching on `intent.target` (`.tab` → tab switch; `.transcriptTime` →
     transcript tab + seek), consuming the intent afterwards.
4. **`Packages/BiscottiKit/Sources/MeetingDetailUI/MeetingDetailView.swift`**
   - Rename the `.task`/`.onChange` hooks to the new view-model API.
5. **`Packages/BiscottiKit/Sources/AppShellUI/AppShellViewModel.swift`**
   - `onLaunchCompletion` closure (set by the app delegate) fired exactly
     once — after the view model's *first* `onLaunch()` call completes — then
     cleared (guards a cancelled-and-rerun `.task` racing the real launch).
   - `linkError` read-through + `dismissLinkError()` passthrough.
6. **`Packages/BiscottiKit/Sources/AppShellUI/AppShellView.swift`**
   - One `.alert` on the body `Group` via the get/set `Binding` pattern
     (single OK → `dismissLinkError()`); a second failure overwrites.
7. **`App/Sources/BiscottiApp.swift`**
   - Remove `WindowRootView.onOpenURL` and `LaunchState.deepLinkHandler`.
   - `AppDelegate`: `application(_:open:)` → `MainActor.assumeIsolated` →
     `enqueueOrHandle` per URL; `pendingLaunchURL`/`isCoreReady`;
     `buildCore` sets `shellViewModel.onLaunchCompletion` to
     `coreLaunchDidComplete()` (flips ready, drains the slot last-wins);
     `handleOpenURL` parses first (parse-tier URLs never foreground), then
     `showMainWindow()`, then `Task { await core?.apply(link) }`.
   - `import AppLinks`.
8. **`App/project.yml`** — add the `AppLinks` product to the app target.
9. **Tests** (below); delete `DeepLinkTests.swift`, rewrite
   `DeepLinkJumpTests.swift`.

## Tests

- `AppCoreTests/AppLinkApplyTests.swift` (replaces `DeepLinkTests`):
  route state per case; meeting link sets selection + intent target
  (incl. tab/time conflict via parsed URL, and no-params → Summary — the
  rewritten `missingTimeIsNoOp`); nonexistent meeting → `linkError ==
  .meetingNotFound` and route untouched; bad event key → `.eventNotFound`;
  `dismissLinkError` clears; onboarding drop; `record` while recording →
  route `.recording`, no second session; `record(title:)` title reaches the
  store; repeated identical links → distinct tokens; `consumeMeetingIntent`.
- `MeetingDetailUITests/DeepLinkJumpTests.swift` (rewritten): intent for
  this meeting switches tab/seeks; seek clamped; other-meeting intent
  untouched and unconsumed; deferred seek after audio load; consume-after-
  apply; no-op; `.tab(.notes)` opens Notes without seek.
- `MeetingDetailUITests/MeetingDetailPhase8Tests.swift`: port the one
  `handleDeepLink` call to `apply(_:)`.
- `AppShellUITests/AppShellViewModelTests.swift`: `onLaunchCompletion`
  fires once (first launch only).
- `RecordingTests/RecordingControllerTests.swift`: `start(title:)` sets
  the title; `start()` keeps "Untitled Meeting".

## Commit staging

`Assets/`, `clean-worktree*.sh` are pre-existing untracked user files —
never stage them. Commit by explicit path:

    git add .gitignore App/project.yml App/Sources/BiscottiApp.swift \
      Packages/BiscottiKit/Package.swift \
      Packages/BiscottiKit/Sources/AppCore/AppCore.swift \
      Packages/BiscottiKit/Sources/AppShellUI \
      Packages/BiscottiKit/Sources/MeetingDetailUI \
      Packages/BiscottiKit/Sources/Recording/RecordingController.swift \
      Packages/BiscottiKit/Tests/AppCoreTests \
      Packages/BiscottiKit/Tests/AppShellUITests/AppShellViewModelTests.swift \
      Packages/BiscottiKit/Tests/MeetingDetailUITests \
      Packages/BiscottiKit/Tests/RecordingTests/RecordingControllerTests.swift \
      specs/projects/app_urls
