---
status: complete
---

# Phase 3: Settings, wiring, and docs

## Overview

Wire the built `MCPServer` module into the app: the persisted `mcpServerEnabled`
setting, the `.mcpServerEnabledDidChange` notification, AppCore ownership of
`MCPServerController` (start on launch, live-apply on setting change), the
General settings row with its four states (Copy button, Retry, How-to-connect
sheet), the `mcp_server` manual test script with its one recordable step, and
the doc updates (`specs/architecture.md` topology, `CLAUDE.md` module list +
staleness rule). Phases 1–2 constraints stay in force: channel-handler-internal
aggregation, bind-before-transport, everything created in `start()` and
released in `stop()`.

## Decisions made while planning (within the decided design)

- **SettingsUI gains `MCPServer` in its Package.swift target deps.**
  Architecture §8.2 says SettingsUI "needs no new package dependency (AppCore
  already re-exports what it owns)" — but no module in this repo uses
  `@_exported import` (zero precedent), and the row must *name*
  `MCPServerState`/`MCPServerConfiguration` to switch on the four states.
  The repo convention is explicit imports (SettingsUI already imports
  Intelligence/LocalLLM/…), so we follow it. The design goal that sentence
  protects — **no app-target change** — still holds: `App/project.yml` is
  untouched; MCPServer ships transitively via AppCore.
- **The wiring test binds the real port 8516** (AppCore only exposes the public
  `start()`). Exactly one test function touches 8516 (the on-launch + observer
  flips are sequenced inside it), so parallel Swift Testing execution can never
  self-conflict; every other start in the suite targets ephemeral ports or is a
  state-guarded no-op. *Hardened after review:* when a foreign process holds
  8516 — typically the real Biscotti app running with MCP on, which is exactly
  what a developer machine looks like while dogfooding — the test disables
  itself via a `SO_REUSEADDR` bind probe (`.disabled(if:)`), because it cannot
  bind the fixed port and nothing is wrong with the code. CI runners always
  have the port free, so the test runs there. The test stops the server it
  started, releasing the port and the listener's event-loop thread.
- **The How-to-connect link renders only in `.running`**, next to the endpoint
  line — the endpoint is the thing the link explains, and in `.starting` /
  `.failed` it is not yet usable. Functional spec §2.1's "when on" is read as
  the *server on* row state.
- **Toggle = intent, caption = reality**: the binding reads/writes
  `viewModel.mcpServerEnabled` (the persisted intent) and is disabled while
  `.starting`; the caption switches on `core.mcpServer.state`. This matches
  §2.1's table, including "toggle stays on" after a bind failure (§2.3).
- **Manual test script id `mcp_server`**, step ids `mcp_connect` (instruction)
  and `mcp_real_client` (recordable `humanQuestion`) — `mcp_*` matches the
  prefix convention the staleness rule uses.

## Steps

1. **`Sources/DataStore/Models/AppSettings.swift`** — add
   `public var mcpServerEnabled: Bool = false` (stored, defaulted; additive →
   no schema version bump, per architecture §7.1), the memberwise-init
   parameter `mcpServerEnabled: Bool = false`, and its assignment.

2. **`Sources/DataStore/DataStore+ReadModels.swift`** — `AppSettingsData`:
   `public var mcpServerEnabled: Bool` + defaulted init parameter; add the
   field to the `settings()` read mapping and to both directions of the
   `updateSettings` read-modify-write.

3. **`Sources/AppCore/AppCore.swift`** —
   - `import MCPServer`; `Notification.Name` extension gains
     `.mcpServerEnabledDidChange`
     (`"net.scosman.biscotti.mcpServerEnabledDidChange"`), same pattern as the
     six existing names;
   - stored `public let mcpServer: MCPServerController`; `init` gains
     `mcpServer: MCPServerController? = nil` (injected controller wins,
     otherwise constructed from `store` — no existing call site or
     `BiscottiTestSupport` fake changes);
   - `startBackgroundServices()`, after the timers: read settings, and
     `if settings.mcpServerEnabled { await mcpServer.start() }` (covers both
     the `onLaunch` and `completeOnboarding` paths; the onboarding-early-return
     path never starts it);
   - `startNotificationSettingsObservers()` gains a fourth task observing
     `.mcpServerEnabledDidChange` → re-read settings →
     `await mcpServer.applyEnabled(settings.mcpServerEnabled)`; appended to
     `notificationSettingsObserverTasks`.

4. **`Package.swift`** — `MCPServer` added to the target deps of `AppCore`,
   `SettingsUI` and to the test deps of `AppCoreTests`, `SettingsUITests`
   (see decisions; no other target needs it — everything else reaches it
   transitively through AppCore).

5. **`Sources/SettingsUI/SettingsViewModel.swift`** —
   - `public private(set) var mcpServerEnabled = false` (General section of
     stored props), loaded in `load()`;
   - `func setMCPServerEnabled(_:) async` in a new "MCP Server actions"
     extension, following the exact `setStopRecordingAutomatically` shape:
     optimistic update → persist → post `.mcpServerEnabledDidChange` → revert
     on throw;
   - forwarding `var mcpServerState: MCPServerState { core.mcpServer.state }`
     (in the computed-forwarding extension) and
     `func retryMCPServer() async { await core.mcpServer.start() }`.

6. **`Sources/SettingsUI/SettingsView.swift`** — `@State var showMCPHelp`
   (internal, so the cross-file row extension can present the sheet, same as
   `showVocabularyListSheet`); `generalSection` gains `mcpRow` as the **final**
   row, after `appUpdatesRow`.

7. **`Sources/SettingsUI/SettingsMCPRow.swift`** (new, cross-file extension
   like `SettingsSystemAudioRow.swift`) — the row: `Toggle("MCP")` bound to the
   intent, disabled while `.starting`; caption `VStack` switching on
   `viewModel.mcpServerState`:
   - `.stopped` → subtitle "Chat with your meeting notes in any agent."
   - `.starting` → "Starting…"
   - `.running(url)` → subtitle + endpoint line (`url.absoluteString`,
     monospaced caption) + `MCPEndpointCopyButton(url)` + "How to connect"
     link (`.buttonStyle(.link)`) → `showMCPHelp = true`; `.sheet` presents
     `MCPHelpSheet`
   - `.failed(err)` → `err.userMessage` in `Tokens.signalRedText` + "Retry"
     (`Task { await viewModel.retryMCPServer() }`)
   `MCPEndpointCopyButton` is a small top-level view (transient "Copied" for
     1.5 s, the MeetingDetailView Copy-button pattern) shared by the row and
     the help sheet.

8. **`Sources/SettingsUI/MCPHelpSheet.swift`** (new, alongside
   `AlertsHelpSheet.swift`) — same sheet chrome (width 400, MD padding):
   the endpoint from `MCPServerConfiguration.endpointURL` with a Copy button,
   the paste-ready JSON snippet (selectable monospaced block), and the exposure
   warning verbatim: *"Any app on this Mac can read your meetings while this
   is on. Nothing leaves your machine unless the agent you connect sends it
   somewhere."*

9. **`Sources/ManualTestKit/Scripts/MCPScript.swift`** (new) —
   `static let mcp = TestScript(id: "mcp_server", title: "MCP Server", steps:)`
   with one `.instruction` (`mcp_connect`: run the real Biscotti app, enable
   Settings → General → MCP, connect a real MCP client with the config snippet
   from "How to connect") and one `.humanQuestion` (`mcp_real_client`: did all
   three tools list and return sane data?). No closures → no app-target wiring
   needed (`WiredScripts.all()`'s `default` passes it through).

10. **`Sources/ManualTestKit/Scripts/AllScripts.swift`** — register `.mcp`.

11. **`ManualTestApp/Results/manual_test_results.json`** — seed
    `mcp_real_client` as `not-run` (no timestamp), so
    `make manual-tests-check` tracks it until a human runs it on hardware.

12. **`Tests/ManualTestKitTests/ScriptShapeTests.swift`** — MCP identity +
    canonical step-id set + internal uniqueness; `allScriptsContainsAll`
    expects 4 and contains `"mcp_server"`; the cross-script uniqueness test
    includes the MCP steps.

13. **`Tests/DataStoreTests/SettingsAndQueryTests.swift`** —
    `mcpServerEnabled` defaults to `false` on first `settings()` and
    round-trips through `updateSettings`.

14. **`Tests/AppCoreTests/MCPServerWiringTests.swift`** (new) — server does
    not start on `onLaunch()` when the setting is off (`.stopped`); when on,
    `onLaunch()` reaches `.running(MCPServerConfiguration.endpointURL)`, and
    the `.mcpServerEnabledDidChange` observer flips it off → `.stopped` and
    back on → `.running` (polls; the observer task is async). Local
    `pollUntil` helper, same as the other AppCore test files.

15. **`Tests/SettingsUITests/SettingsMCPTests.swift`** (new) —
    `mcpServerEnabled` default false + loaded from store;
    `setMCPServerEnabled(true)` updates the VM, persists, and posts the
    notification (observer-token pattern); `mcpServerState` forwards the
    controller state.

16. **`specs/architecture.md`** — add MCPServer to the topology: L1 Services
    line, a component card in the Service modules section, AppCore's
    "Depends on" list, and the mermaid graph (`CORE --> MCPS[MCPServer]`,
    `MCPS --> STORE`).

17. **`CLAUDE.md`** — extend the manual-test staleness rule to cover
    `Packages/BiscottiKit/Sources/MCPServer` and the `mcp_*` prefix (same
    wording pattern as the existing rule); note the MCPServer module in the
    current-stage paragraph.

## Tests

- `SettingsTests.mcpServerEnabledDefaultsFalse` — first `settings()` call
  creates the singleton with the field `false` (off by default).
- `SettingsTests.mcpServerEnabledRoundTrip` — `updateSettings` persists a
  flip to `true`; a fresh `settings()` reads it back.
- `MCPServerWiringTests.serverNotStartedWhenDisabled` — onboarding complete +
  setting off → `onLaunch()` leaves `core.mcpServer.state == .stopped`.
- `MCPServerWiringTests.serverStartsWhenEnabledAndObserverFlips` — setting on
  → `.running(endpointURL)`; post the notification with the setting flipped
  off → `.stopped`; flipped on → `.running` again (live observer path).
- `SettingsMCPTests` — default/load/persist/notification-post/forwarding as
  in step 15.
- `ScriptShapeTests` additions — the `mcp_server` script is registered in
  `allScripts` (count 4) with exactly the canonical step-id set
  {`mcp_connect`, `mcp_real_client`} and unique ids across scripts.
- `CIGateTests.resultsFileCoversAllStepIDs` (existing) — keeps passing because
  step 11 seeds the `not-run` entry for `mcp_real_client`.
