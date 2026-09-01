---
status: complete
---

# Phase 3: Producers, docs, manual test

## Overview

The consumer-facing half of the URL vocabulary: `biscotti_get_meeting`
returns an `app_url`, a **Copy Meeting Link** command lands in the list
context menu and the detail overflow menu, `App/deeplinks.md` documents
the vocabulary for external integrators, and the `app_urls` ManualTestKit
script proves cold-launch / menu-bar-only / background delivery on real
hardware. Per the staleness rule, the `mcp_*` manual steps are marked
`not-run` because `MCPServer` changes. Architecture §6–§9.

## Steps

1. **MCP `app_url`** (architecture §6)
   - `MeetingToolPayloads.swift`: `MeetingDetailPayload` gains
     `let appURL: String` (`CodingKeys` case `app_url`); custom `encode`
     emits it always.
   - `MeetingToolProvider.swift`: `import AppLinks`; populate as
     `AppLink.meeting(id: id, target: .tab(.summary)).url.absoluteString`.
   - `MeetingToolCatalog.swift`: `getMeeting` outputSchema gains
     `"app_url"` property (string, description pointing at
     `App/deeplinks.md`) and joins the `required` list.
2. **Copy Meeting Link** (architecture §7)
   - `AppCore.swift`: `import AppKit`; `copyMeetingLink(_:writer:)` in the
     app-link extension — builds
     `AppLink.meeting(id:target:.tab(.summary)).url.absoluteString` and
     hands it to `writer`, whose default performs the real
     `NSPasteboard` write (the seam: tests capture the string, production
     needs no injection).
   - `MeetingListViewModel`: passthrough `copyMeetingLink(_:)`;
     `MeetingListView.contextMenu` gains "Copy Meeting Link" guarded on
     `ids.count == 1` (before Delete).
   - `MeetingDetailViewModel`: passthrough `copyMeetingLink()`;
     `MeetingDetailView.overflowMenu` gains the command unconditionally
     (first item, `link` system image).
3. **`App/deeplinks.md`** (architecture §8): every route with parameters,
   defaults, and a copy-pasteable `open 'biscotti://…'` example; the
   tab/time resolution order; bad-URL expectations (parse tier silent,
   existence tier alert); machine-local caveat. Written for an integrator
   with no access to this repo.
4. **`app_urls` manual test script** (architecture §9.4)
   - `ManualTestKit/Scripts/AppURLsScript.swift` (`TestScript.appURLs`,
     id `app_urls`): setup instruction (real Biscotti registered with
     LaunchServices, past onboarding); one `.action` +
     `.humanQuestion` pair for each fixed route (`home`, `meetings`,
     `settings`, `search?query=`, `record`); instruction + three
     `.action`/`.humanQuestion` pairs that read a **copied meeting link**
     off the pasteboard (as-is, `?tab=notes`, `?time=30`); three
     `.instruction` + `.humanQuestion` delivery-state pairs (cold launch,
     menu-bar only, background) using Terminal `open`. Placeholder
     closures only — ManualTestKit stays dependency-free.
   - `AllScripts.swift`: register `.appURLs`.
   - `WiredScripts.swift`: `wireAppURLs` substitutes
     `NSWorkspace.shared.open` (throws if the system refuses), reads the
     pasteboard, validates `AppLink.meeting`, rebuilds variants through
     `AppLink`. `NoMeetingLinkError` tells the human to copy a link first.
   - `ManualTestApp/project.yml`: add the `AppLinks` product.
5. **Staleness rule**: `manual_test_results.json` — `mcp_real_client`
   set to `"not-run"` (MCPServer source changed).
6. **Test updates**
   - `MeetingToolPayloadTests`: fixtures gain `appURL`; key-surface sets
     gain `app_url`; null-decode JSON fixture gains `app_url`.
   - `MeetingToolDetailTests`: rich + sparse payloads assert the exact
     `app_url` string.
   - `MCPToolRoundTripTests`: assert `app_url` over the wire.
   - `AppLinkApplyTests`: `copyMeetingLink` hands the canonical Summary
     link to the writer.
   - `ScriptShapeTests`: `allScripts.count == 5`; app_urls identity,
     step-count, ID-set, and uniqueness coverage.

## Tests

- `copyMeetingLinkWritesCanonicalURL` — writer receives
  `biscotti://meeting/{uuid}` (no query — Summary default).
- `getMeetingRichPayload` / `getMeetingSparsePayload` — `app_url` always
  present with the canonical string.
- `detailPayloadKeys` / `detailPayloadFullKeys` / `detailPayloadDecodesNulls`
  — `app_url` on the wire contract (required, non-optional).
- `detailAndTranscriptOverWire` — `app_url` survives the HTTP leg.
- `ScriptShapeTests` — the new script is registered and structurally sound.

## Commit staging

`Assets/`, `clean-worktree*.sh` are pre-existing untracked user files —
never stage them. Commit by explicit path:

    git add App/deeplinks.md ManualTestApp/project.yml \
      ManualTestApp/Sources/WiredScripts.swift \
      ManualTestApp/Results/manual_test_results.json \
      Packages/BiscottiKit/Sources/MCPServer \
      Packages/BiscottiKit/Sources/AppCore/AppCore.swift \
      Packages/BiscottiKit/Sources/MeetingListUI \
      Packages/BiscottiKit/Sources/MeetingDetailUI \
      Packages/BiscottiKit/Sources/ManualTestKit \
      Packages/BiscottiKit/Tests/MCPServerTests \
      Packages/BiscottiKit/Tests/AppCoreTests/AppLinkApplyTests.swift \
      Packages/BiscottiKit/Tests/ManualTestKitTests/ScriptShapeTests.swift \
      specs/projects/app_urls
