---
status: complete
---

# Phase 1: Swift package + command surface (the gating core)

## Overview

Create the foundational BiscottiKit Swift package with a placeholder module and test, plus the developer command surface (Makefile), dev tool definitions (Brewfile), lint/format configuration (.swiftformat, .swiftlint.yml), and .gitignore updates. This is the gating core that all subsequent phases build on.

## Steps

1. Create `Packages/BiscottiKit/Package.swift` — Swift tools 6.2 (minimum for `treatAllWarnings(as:)`), macOS 15 platform, single `BiscottiKit` library target with `warningsAsErrors` swift settings, `BiscottiKitTests` test target, `swiftLanguageModes: [.v6]`.

2. Create `Packages/BiscottiKit/Sources/BiscottiKit/BiscottiKit.swift` — placeholder `public enum BiscottiKit` with `public static let marker = "BiscottiKit linked"`.

3. Create `Packages/BiscottiKit/Tests/BiscottiKitTests/BiscottiKitTests.swift` — Swift Testing `@Test func markerIsPresent()` verifying the marker value.

4. Create `Brewfile` — xcodegen, swiftlint, swiftformat (no uv per user constraint, no node needed in Phase 1).

5. Create `Makefile` — targets: help, bootstrap, build, test, lint, format, clean. Phase 1 omits generate/build-app/test-app/hooks/ci (those arrive in Phases 2 and 3). LINT_PATHS covers Packages only (App/ doesn't exist yet).

6. Create `.swiftformat` — pin Swift version 6.0, exclude .build dirs and generated projects, configure self/import/commas/trimwhitespace rules.

7. Create `.swiftlint.yml` — strict mode, included/excluded paths, disabled formatting rules (to avoid conflict with SwiftFormat), opt-in stricter rules. Note: `unused_declaration` and `unused_import` are analyzer rules — include them but remove if they cause issues with `swiftlint lint`.

8. Update `.gitignore` — add `**/.build/`, `.DS_Store`, `*.xcuserstate` entries that aren't already present. Ensure `App/Biscotti.xcodeproj/` is covered by the existing `*.xcodeproj/` glob.

## Tests

- `BiscottiKitTests/markerIsPresent`: verifies `BiscottiKit.marker == "BiscottiKit linked"` — proves the package compiles and the test tier runs.

## Verification

- `make bootstrap` installs tools via Homebrew
- `make build` compiles the package
- `make test` runs and passes the single test
- `make lint` passes clean on the skeleton
- `make format` is a no-op on already-clean code
