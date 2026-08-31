---
status: draft
---

# Architecture: App URLs

Single architecture doc — the project is small enough (one new leaf module,
one new app-delegate entry point, a handful of `AppCore` methods) that
per-component docs would add ceremony without adding clarity.

## 1. Component map

```
                    ┌─────────────────┐
                    │   AppLinks      │  NEW leaf module, Foundation only
                    │  AppLink (enum) │  parse + build + MeetingTab
                    └────────┬────────┘
             ┌───────────────┼────────────────┐
             │               │                │
        ┌────▼─────┐   ┌─────▼──────┐  ┌──────▼────────┐
        │ AppCore  │   │ MCPServer  │  │ MeetingDetailUI│
        │ handle() │   │  app_url   │  │  tab mapping   │
        └────▲─────┘   └────────────┘  └───────────────┘
             │
   ┌─────────┴──────────┐
   │ AppDelegate        │  App target
   │ application(_:open:)│
   └────────────────────┘
```

### Why a new module

`MCPServer` needs to *build* a URL (§7 of the functional spec) and `AppCore`
needs to *parse* one. `AppCore` already depends on `MCPServer`, so the shared
type cannot live in `AppCore` without inverting that edge. `AppLinks` is a
leaf with no dependencies beyond Foundation — the same shape as
`MeetingCatalog`. It is pure value types and pure functions, so it unit-tests
with no fixtures, no store, and no main actor.

`MeetingTab` lives here too, because `AppCore` must carry a tab in its
pending-intent state while the concrete `MeetingDetailViewModel.Tab` lives in
`MeetingDetailUI` (which depends on `AppCore`, not the reverse).

## 2. `AppLinks` module

New target `Packages/BiscottiKit/Sources/AppLinks`, exported as a library,
plus `Tests/AppLinksTests`. Added to `AppCore`, `MCPServer` and
`MeetingDetailUI` dependency lists.

### 2.1 The parsed intent

```swift
public enum AppLink: Sendable, Equatable {
    case home
    case meetings
    case settings
    case meeting(id: UUID, target: MeetingTarget)
    case search(query: String)
    case upcoming(key: String)
    case record(title: String?)
}

/// Where inside a meeting the link points.
public enum MeetingTarget: Sendable, Equatable {
    case tab(MeetingTab)          // ?tab=…, or the default .summary
    case transcriptTime(TimeInterval) // ?time=… (implies the transcript tab)
}

public enum MeetingTab: String, Sendable, Equatable, CaseIterable {
    case summary, transcript, notes
}
```

`MeetingTarget` encodes the §4.4 resolution order as *data* rather than as
two optional fields the consumer must re-prioritize. Parsing decides once;
every consumer just switches. This is why `tab` + `time` conflicts cannot be
mishandled downstream — the conflict is resolved before the value exists.

### 2.2 Parsing

```swift
public extension AppLink {
    /// Parses a `biscotti://` URL. Returns nil for anything unrecognized.
    init?(url: URL)
}
```

Implementation notes:

- Parse via `URLComponents(url:resolvingAgainstBaseURL: false)`, which
  percent-decodes query values (R9). Bail if it returns nil.
- `scheme?.lowercased() == "biscotti"` (R1), else nil.
- Switch on `host?.lowercased()` (R2). `default: nil` (R3).
- Query lookup helper: first item matching a name, so unknown parameters are
  structurally ignored (R8).
- `meeting`: strip the leading `/` from `path`, `UUID(uuidString:)`. Then
  `time` first (`Double(_:)`), else `tab` (`MeetingTab(rawValue:lowercased)`),
  else `.tab(.summary)`. An unrecognized `tab` value falls through to
  `.summary` rather than failing the whole URL (R8).
- `search`: `query` must be *present*; its value may be empty. Distinguishing
  present-and-empty from absent is why this reads `queryItems` directly rather
  than using a `nonEmpty` helper — a subtlety the tests pin down.
- `record`: `title` trimmed of whitespace; empty becomes `nil`.
- `upcoming`: `key` must be present and non-empty.

Note the parser does **not** check whether a meeting exists — that needs the
store and is async. It is a pure function; existence is `AppCore`'s job
(§3.2). This keeps `AppLinks` free of any dependency and instantly testable.

### 2.3 Building

```swift
public extension AppLink {
    /// The canonical URL for this link. Non-failable: every case maps to a
    /// well-formed URL.
    var url: URL
}
```

Built with `URLComponents` so values are percent-encoded. Round-trip test:
for a table of every case, `AppLink(url: link.url) == link`.

`Recording/NotesMarkdown.swift` is not touched (functional spec §6).

## 3. `AppCore` changes

### 3.1 Replacing `TranscriptJump`

`TranscriptJump` (meetingID + time) is replaced by a wider pending intent:

```swift
public struct MeetingOpenIntent: Sendable, Equatable {
    public let meetingID: UUID
    public let target: MeetingTarget
    /// Monotonic; distinguishes two identical intents (see below).
    public let token: UInt
}

public private(set) var pendingMeetingIntent: MeetingOpenIntent?
```

**Why the token.** `MeetingDetailView` reacts via
`.onChange(of: viewModel.pendingJumpToken)`, and `AppShellViewModel`
*caches* the detail view model per meeting ID. Opening the identical URL
twice in a row would set an `Equatable`-equal value, `onChange` would not
fire, and the second click would appear to do nothing — on an already-open
meeting, nothing at all would happen. A monotonically increasing token makes
every intent distinct. (This latent bug exists today with `TranscriptJump`;
it is invisible only because the notes links always carry distinct times.)

`consumeTranscriptJump()` becomes `consumeMeetingIntent()`.

### 3.2 The entry point

Parsing stays in the delegate (it is synchronous and decides whether to
foreground); `AppCore` receives an already-parsed link:

```swift
public extension AppCore {
    /// Applies a parsed link. Sets `linkError` if the target is missing.
    func apply(_ link: AppLink) async
}
```

Taking `AppLink` rather than `URL` is what keeps this simple: no `Bool`
return to thread back for foregrounding, and the tests exercise intents
rather than re-testing string parsing already covered in `AppLinksTests`.

Flow:

1. `guard route != .onboarding else { log.debug; return }` (R6)
2. Switch and apply:

| Case | Action |
|---|---|
| `.home` | `showHome()` |
| `.meetings` | `showMeetings()` |
| `.settings` | `showSettings()` |
| `.meeting` | `store.meetingExists(id:)`; false → `linkError = .meetingNotFound`, route untouched. Else `select(id)` + set `pendingMeetingIntent` |
| `.search` | `showMeetings()`, `setMeetingsQuery(q)`, `focusSearch()` |
| `.upcoming` | `calendar.event(forKey:)`; nil → `linkError = .eventNotFound`. Else `selectEvent(key)` |
| `.record` | if already recording → `route = .recording`. Else `await startRecording(title:)` |

`handleDeepLink(_:)` is removed; its one caller is the delegate. Callers that
want the old timestamp-jump behavior get it unchanged through `.meeting` with
a `.transcriptTime` target.

### 3.2.1 The alert

```swift
public enum AppLinkError: String, Sendable, Equatable {
    case meetingNotFound, eventNotFound
    public var title: String { … }
    public var message: String { … }
}

public internal(set) var linkError: AppLinkError?
public func dismissLinkError() { linkError = nil }
```

`AppShellView` gains one `.alert` bound through the get/set `Binding`
pattern already used for `showReTranscribeAfterCorrection` in
`MeetingDetailView`, with a single OK button calling `dismissLinkError()`.
A second failure overwrites the first (functional spec §8).

Modelling this as an enum rather than a `String?` keeps the copy out of
`AppCore` and lets tests assert on a case instead of matching prose.

### 3.3 `startRecording` gains a title

```swift
func startRecording(eventKey: String? = nil, title: String? = nil) async
```

It threads through `completeRecordingStartup` (which stashes
`pendingStartupEventKey` for retry — a parallel `pendingStartupTitle` is
added) to `RecordingController.start(title:)`, which passes it to
`store.createMeeting(title:)` in place of `Self.autoTitle()`. Default `nil`
preserves every existing call site.

No new suppression flag is needed for AI titling: `Intelligence` already
skips any meeting whose title differs from `Meeting.defaultTitle`.

## 4. `MeetingDetailUI` changes

`applyPendingJumpIfNeeded()` becomes `applyPendingIntentIfNeeded()`:

```swift
guard let intent = core.pendingMeetingIntent,
      intent.meetingID == meetingID else { return }
switch intent.target {
case let .tab(tab):
    selectedTab = Tab(tab)        // MeetingTab -> local Tab
case let .transcriptTime(time):
    selectedTab = .transcript
    pendingSeek = time
    applySeekIfReady()
}
core.consumeMeetingIntent()
```

A small `init(_ MeetingTab)` maps the AppCore-level enum to the view model's
own `Tab`. The two enums stay separate deliberately: `MeetingDetailViewModel.Tab`
carries display strings (`"Summary"`) and is a view concern.

The view's `.onChange(of: viewModel.pendingJumpToken)` is renamed to match but
keeps its shape.

**Interaction with existing auto-tab-switches.** `onPipelineActiveChange` and
`runSummary` force `selectedTab = .summary`. If a `?tab=notes` link opens a
meeting whose enhancement pipeline then activates, the pipeline wins and
yanks the user to Summary. This is pre-existing behavior for any manual tab
choice, is rare (only during active enhancement), and is left alone rather
than adding precedence tracking.

## 5. Delivery — app target

### 5.1 The delegate

```swift
func application(_ application: NSApplication, open urls: [URL]) {
    MainActor.assumeIsolated { urls.forEach(enqueueOrHandle) }
}
```

`WindowRootView.onOpenURL` is **removed** so a URL is never handled twice.

AppKit calls `application(_:open:)` on the main thread for both cold launch
and a running app, with or without windows — which is exactly the coverage
the functional spec §5 table requires and the reason `onOpenURL` was
insufficient.

### 5.2 The cold-launch race

`AppCore.onLaunch()` runs from `AppShellView.task`, so on cold launch the URL
can arrive before the core is ready (and before the onboarding gate is known).
`AppDelegate` gets:

```swift
private var pendingLaunchURL: URL?
private var isCoreReady = false
```

- `enqueueOrHandle(url)`: if `isCoreReady`, handle now; else
  `pendingLaunchURL = url` (last wins, per the confirmed decision).
- `AppCore.onLaunch()` completing flips `isCoreReady` and drains the slot.
  `AppShellViewModel.onLaunch()` already wraps `core.onLaunch()`; it gains a
  completion callback the delegate sets, rather than the delegate polling.
- Draining runs the same `handleOpenURL` path, including the R6 onboarding
  check — so a URL that arrives during a cold launch into onboarding is
  parsed, dropped, and never foregrounds.

### 5.3 Foregrounding

```swift
@MainActor func handleOpenURL(_ url: URL) {
    guard let link = AppLink(url: url) else { return }   // R3 parse tier
    showMainWindow()                                      // R4
    Task { @MainActor in await core?.apply(link) }
}
```

The parse guard runs first and is synchronous, so a malformed URL costs
nothing and never opens a window. Everything that parses foregrounds
immediately — the existing code shape is preserved, with no ordering
inversion and no spinner, because resolution completes faster than the
window animation.

## 6. MCP `app_url`

- `MeetingDetailPayload` gains `let appURL: String` with
  `case appURL = "app_url"`.
- Populated as `AppLink.meeting(id: id, target: .tab(.summary)).url.absoluteString`.
- `MeetingToolCatalog` adds `"app_url": ["type": "string", "description": …]`
  to the `get_meeting` output schema and to its `required` list, with the
  description pointing at `App/deeplinks.md`.
- `MCPServer` gains an `AppLinks` dependency.

Existing MCP payload tests assert on decoded structs, so adding a required
field means updating those fixtures — expected, and it is how we know the
schema and payload stayed in sync.

## 7. Documentation

New `App/deeplinks.md`, per functional spec §9. Content is the §4 vocabulary
written for an external integrator, with a copy-pasteable
`open 'biscotti://…'` example per route.

## 8. Testing

### 8.1 `AppLinksTests` (new, pure, fast)

Table-driven over `(urlString, expected: AppLink?)`. Covers every route, the
§4.4 resolution order including the `tab`+`time` conflict, case-insensitivity
of scheme/host/tab, unknown parameters ignored, `search?query=` empty vs.
absent, `record?title=` whitespace-only → `nil`, and every rejection in R3.
Plus the build→parse round-trip over all cases.

### 8.2 `AppCoreTests` (rewriting `DeepLinkTests`)

Per-route state assertions; a nonexistent meeting setting
`linkError == .meetingNotFound` *and* leaving `route` untouched; an
unresolvable event key setting `.eventNotFound`; `dismissLinkError()`
clearing it; the onboarding drop (R6); `record` while recording routing to
`.recording` without starting a second session; `record?title=` reaching the
store; and repeated identical links producing distinct tokens (§3.1).

`DeepLinkTests.missingTimeIsNoOp` is rewritten to assert the meeting opens on
Summary.

### 8.3 Not unit-testable

`application(_:open:)` and the cold-launch drain live in the app target,
which has no test host (`make test-app` is empty). They are covered by the
manual script — which is precisely the split the repo already uses.

### 8.4 Manual test script

New `AppURLsScript.swift` in `ManualTestKit/Scripts/`, added to
`allScripts`. Follows the established pattern: the script declares steps with
placeholder closures; `ManualTestApp/Sources/WiredScripts.swift` substitutes
real ones. `ManualTestKit` keeps its zero-dependency status — the wired
closures call `NSWorkspace.shared.open(_:)` from the app target.

Fixed-URL routes (`home`, `meetings`, `settings`, `search?query=…`,
`record`) are one `.action` button each plus a `.humanQuestion`.

**Getting a real meeting UUID.** The meeting routes need a UUID from the
user's actual library, which ManualTestApp cannot invent. It must not read
Biscotti's SwiftData store directly — a second process on a live SwiftData
file risks lock contention and is not a supported configuration. Instead the
wired action calls the running app's **MCP server** over
`127.0.0.1:8516` (`biscotti_query_meetings`, take the first result's `id`),
then opens `biscotti://meeting/{id}`, `…?tab=notes` and `…?time=30`.

This has a real benefit: it makes the manual script the end-to-end test of
the `app_url` field from §6, which is otherwise only unit-tested. Its cost is
a precondition — the MCP toggle must be on — stated in the script's first
`.instruction` step, with the fallback of copying a timestamp link out of any
meeting's Notes if the human would rather not enable it.

The three delivery states unit tests cannot reach (cold launch, menu-bar
only, background) are `.instruction` + `.humanQuestion` pairs, as in the MCP
script.

Per the staleness rule in `CLAUDE.md`, only recordable steps are written to
`manual_test_results.json`. Note this project touches none of the four
libraries the rule names (`Transcription`, `AudioCapture`, `LocalLLM`,
`MCPServer`) — except `MCPServer`, via §6. So `mcp_*` steps must be marked
`not-run` when the `app_url` change lands.

## 9. Risks

| Risk | Mitigation |
|---|---|
| Removing `onOpenURL` regresses a path AppKit doesn't cover | The manual script tests all four delivery states explicitly before this ships |
| `application(_:open:)` not firing under ad-hoc signing / stale LaunchServices registration | Script's first instruction covers re-registering; a stale registered copy of Biscotti is the most likely false failure |
| An alert on every stale link becomes noise | Only two triggers, both meaning a real target vanished; a link that merely fails to parse stays silent |
