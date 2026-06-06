---
status: complete
---

# Project 0 — Scaffolding & Tooling

The repo skeleton everything else is built in. This is Project 0 from the [build roadmap](../../../implementation_plan.md): the foundation infrastructure Project, with no runnable product features. It exists largely to nail the historically painful part — `xcodebuild`/CI reliability and the macOS app/package split — exactly once, so every later Project inherits a green, agent-friendly build.

## What it delivers

The repo skeleton: a buildable, empty `BiscottiKit` package plus a thin `App` Xcode project that launches, with green CI — matching the [`Packages/` + `App/` workspace layout](../../../architecture.md#workspace-layout) and the thin-app composition rule from `architecture.md`.

## In scope (from the roadmap entry)

- The `Packages/` + `App/` workspace layout from `architecture.md`.
- `BiscottiKit` package skeleton (the shared app package that will hold most modules as targets).
- Thin app-target shell that launches (window + menu-bar presence), carrying no business logic.
- **Dev signing:** lock in the **stable production bundle ID** (TCC grants depend on it) plus ad-hoc/local signing for dev & CI builds. (Real Developer ID notarization is the separate Distribution Project, #9.)
- Entitlements + Info.plist usage strings per `research/permissions`.
- CI (GitHub Actions) running the **gating package-test tier** (`swift test`) and the **non-gating app/UI tier** (`xcodebuild`).
- Lint + format (fix & check) + a pre-commit hook.
- Agent/build integration: **`hooks_mcp`** ([scosman/hooks_mcp](https://github.com/scosman/hooks_mcp)) as the primary agent command surface (a `hooks_mcp.yaml` exposing our common commands, wrapping the Makefile), plus XcodeBuildMCP for the rare `xcodebuild`/run paths — registered via a checked-in `.mcp.json`.
- Repo `CLAUDE.md` updated with the check commands.

## Author's tooling direction (to be validated/refined during specing)

Author is not a Swift-tooling expert and invited push-back. Proposed starting point:

- Swift Package Manager (SPM).
- SwiftLint, opting into a stricter rule set.
- SwiftFormat.
- Testing: `swift test` for packages; a separate `xcodebuild` check for the app (minimal).
- GitHub Actions for CI.
- Strict (Swift 6 `complete`) concurrency.
- A simple Makefile (`make lint`, `make format`, `make test`) so local and CI share commands.
- A pre-commit hook (template the developer copies into `.git/hooks`).
- Warnings-as-errors / strict-concurrency build settings:
  ```
  SWIFT_STRICT_CONCURRENCY = complete        # Swift 6 concurrency model
  SWIFT_TREAT_WARNINGS_AS_ERRORS = YES
  CLANG_TREAT_WARNINGS_AS_ERRORS = YES
  OTHER_SWIFT_FLAGS = -warnings-as-errors
  GCC_TREAT_WARNINGS_AS_ERRORS = YES
  ```

## Resolved decisions (during specing)

- **Xcode project management:** **XcodeGen** — a checked-in `project.yml` generates `Biscotti.xcodeproj` (gitignored); no hand-edited `.pbxproj`, no merge conflicts, regenerated in CI.
- **Stable production bundle ID:** **`net.scosman.biscotti`** (locked now; TCC grants persist against it). Supersedes the `com.biscotti.app` placeholder in `research/permissions`.
- **App shell scope:** **bare window only** — a `WindowGroup` placeholder that launches. `MenuBarExtra` + accessory (background) activation are deferred to Project 4 (which owns `AppShellUI`/`MenuBarUI`).

## Depends on

Nothing. This is the first Project; every other Project depends on it.

## Risk

**Medium** — `xcodebuild`/CI reliability is the historically painful part; this Project exists largely to nail it once.

## Explicitly out of scope

- The XPC service target (`BiscottiTranscriber.xpc`) — built in Project 1 (Transcription).
- Real Developer ID signing, hardened runtime, notarization, release packaging — Project 9 (Distribution).
- Any real module/business logic, UI screens, or data model — later Projects.
- The manual-test harness app — its own future Project.
