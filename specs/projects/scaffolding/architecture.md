---
status: complete
---

# Architecture: Project 0 — Scaffolding & Tooling

This is the **concrete, file-level** design for the scaffolding. Because the deliverable *is* configuration, the architecture is mostly exact file contents — the coding agent transcribes and verifies them, it doesn't design. Where a value must be confirmed against the installed toolchain at build time (tool versions), that's called out.

**Single-doc decision:** this Project is one coherent infrastructure effort with no internally-complex components, so everything lives here — no `components/` split. It runs long only because config files are verbose.

Inputs: [`project_overview.md`](project_overview.md), [`functional_spec.md`](functional_spec.md), the repo [`architecture.md`](../../architecture.md) (workspace layout / thin-app rule) and [`research/permissions`](../../research/permissions/README.md).

---

## 0. Resolved technical choices (no decisions left for the coder)

| Choice | Decision | Rationale |
|---|---|---|
| Swift tools version | `// swift-tools-version: 6.2` | `treatAllWarnings(as:)` requires PackageDescription 6.2+ (not available at 6.0 despite earlier assumption). |
| Language mode | `swiftLanguageModes: [.v6]` | = complete concurrency by default. |
| Test framework (packages) | **Swift Testing** (`import Testing`) | Modern, bundled with the Swift 6 toolchain; idiomatic for a fresh package. XCTest still allowed where a tool needs it. |
| App test tier | Build-only for now; no XCUITest target yet | Functional spec keeps Tier 2 non-gating and the UI suite empty. A test target is added when there's UI to test (Project 4). |
| Dev tools | Homebrew `Brewfile` | Author's call (simplicity over Mint's exact pins). |
| Xcode/runner | `macos-15` runner, **runner-default Xcode (unpinned for now)** | Avoids a stale pin; the `macos-15` image ships a current Xcode (26/27) with a Swift 6 toolchain. Pin later only if a build needs a specific version. |
| Placeholder module | Single `BiscottiKit` library target, one trivial symbol | Proves app↔package link + test tier; replaced by real modules later. |

---

## 1. Final directory tree (what this Project creates)

```
/
├── Packages/
│   └── BiscottiKit/
│       ├── Package.swift
│       ├── Sources/BiscottiKit/BiscottiKit.swift
│       └── Tests/BiscottiKitTests/BiscottiKitTests.swift
├── App/
│   ├── project.yml
│   ├── Sources/BiscottiApp.swift
│   ├── Resources/
│   │   ├── Info.plist
│   │   └── Assets.xcassets/AppIcon.appiconset/Contents.json   (empty placeholder)
│   └── Biscotti.entitlements
├── .github/workflows/ci.yml
├── .githooks/pre-commit                      (executable)
├── Brewfile
├── Makefile
├── hooks_mcp.yaml
├── .mcp.json
├── .swiftlint.yml
├── .swiftformat
├── .gitignore
└── CLAUDE.md                                 (edited, not created)
```

`App/Biscotti.xcodeproj/` is **generated** by XcodeGen and **gitignored**.

---

## 2. `Packages/BiscottiKit/Package.swift`

```swift
// swift-tools-version: 6.2
// 6.2 (not 6.0) because treatAllWarnings(as:) requires PackageDescription 6.2+.
import PackageDescription

let package = Package(
    name: "BiscottiKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BiscottiKit", targets: ["BiscottiKit"])
    ],
    targets: [
        .target(
            name: "BiscottiKit",
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "BiscottiKitTests",
            dependencies: ["BiscottiKit"],
            swiftSettings: warningsAsErrors
        )
    ],
    swiftLanguageModes: [.v6]
)

// Applied to every target so the whole package is held to the strict bar.
let warningsAsErrors: [SwiftSetting] = [.treatAllWarnings(as: .error)]
```

> **Note:** `treatAllWarnings(as:)` requires PackageDescription 6.2+ (it was introduced in Swift 6.2, not 6.0). `swiftLanguageModes` is available from 6.0+. The tools version is set to 6.2 as the minimum that supports both. Declaring `let warningsAsErrors` after use is fine — top-level `let` in a manifest is in scope for the whole file.

### `Sources/BiscottiKit/BiscottiKit.swift`
```swift
/// Placeholder for the scaffolding Project. Real modules (DataStore, Permissions,
/// the UI modules, …) are added as targets in their own Projects; this single symbol
/// only proves the app↔package link and the test tier compile/run.
public enum BiscottiKit {
    /// Human-readable marker the app shell renders to prove linkage.
    public static let marker = "BiscottiKit linked"
}
```

### `Tests/BiscottiKitTests/BiscottiKitTests.swift`
```swift
import Testing
@testable import BiscottiKit

@Test func markerIsPresent() {
    #expect(BiscottiKit.marker == "BiscottiKit linked")
}
```

---

## 3. App target (XcodeGen)

### `App/project.yml`
```yaml
name: Biscotti
options:
  bundleIdPrefix: net.scosman
  deploymentTarget:
    macOS: "15.0"
  createIntermediateGroups: true

settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
    SWIFT_TREAT_WARNINGS_AS_ERRORS: YES
    CLANG_TREAT_WARNINGS_AS_ERRORS: YES
    GCC_TREAT_WARNINGS_AS_ERRORS: YES
    OTHER_SWIFT_FLAGS: "$(inherited) -warnings-as-errors"
    CODE_SIGN_STYLE: Manual
    CODE_SIGN_IDENTITY: "-"          # ad-hoc; real cert is Project 9
    DEVELOPMENT_TEAM: ""

packages:
  BiscottiKit:
    path: ../Packages/BiscottiKit

targets:
  Biscotti:
    type: application
    platform: macOS
    deploymentTarget: "15.0"
    sources:
      - Sources
      - Resources
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: net.scosman.biscotti
        INFOPLIST_FILE: Resources/Info.plist
        CODE_SIGN_ENTITLEMENTS: Biscotti.entitlements
        MARKETING_VERSION: "0.0.1"
        CURRENT_PROJECT_VERSION: "1"
    dependencies:
      - package: BiscottiKit
        product: BiscottiKit

schemes:
  Biscotti:
    build:
      targets:
        Biscotti: all
    run:
      config: Debug
    test:
      config: Debug
```

> Paths are relative to `App/` (where `project.yml` lives), so the package is `../Packages/BiscottiKit`. `make build-app` runs `xcodegen generate` (cwd `App/`) before building.

### `App/Sources/BiscottiApp.swift`
```swift
import SwiftUI
import BiscottiKit

@main
struct BiscottiApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 8) {
                Text("Biscotti").font(.largeTitle)
                Text(BiscottiKit.marker).foregroundStyle(.secondary)
            }
            .frame(minWidth: 360, minHeight: 240)
            .padding()
        }
    }
}
```
No `MenuBarExtra`, no accessory activation, no `DataStore`/`AppCore` — all deferred (functional spec §6).

### `App/Resources/Info.plist` (keys; standard app boilerplate omitted)
```xml
<key>NSMicrophoneUsageDescription</key>
<string>Biscotti needs microphone access to record your voice during meetings.</string>
<key>NSAudioCaptureUsageDescription</key>
<string>Biscotti needs system audio access to record other meeting participants.</string>
<key>NSCalendarsFullAccessUsageDescription</key>
<string>Biscotti reads your calendar to show upcoming meetings and enrich recordings with event details.</string>
```
Strings are research drafts; product may reword. (`LSUIElement` is **not** set — ordinary foreground app for now.)

### `App/Biscotti.entitlements`
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
```
Hardened runtime is **not** enabled here (Project 9). The entitlement is harmless without it and saves a retrofit for the audio Projects.

---

## 4. `Makefile` (the canonical command surface)

```make
.DEFAULT_GOAL := help
SHELL := /bin/bash

PACKAGES := Packages/BiscottiKit
LINT_PATHS := Packages App

.PHONY: help bootstrap generate build test lint format build-app test-app hooks ci clean

help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'

bootstrap: ## Install dev tools via Homebrew
	@command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh"; exit 1; }
	brew bundle --file=Brewfile

generate: ## Generate the Xcode project from project.yml
	cd App && xcodegen generate

build: ## Build all SPM packages
	swift build --package-path $(PACKAGES)

test: ## GATING: run package tests
	swift test --package-path $(PACKAGES)

lint: ## Check formatting + lint (non-mutating)
	swiftformat --lint $(LINT_PATHS)
	swiftlint lint --strict $(LINT_PATHS)

format: ## Auto-format then autofix lint
	swiftformat $(LINT_PATHS)
	swiftlint lint --fix $(LINT_PATHS)

build-app: generate ## NON-GATING: build the app via xcodebuild (ad-hoc)
	cd App && xcodebuild -project Biscotti.xcodeproj -scheme Biscotti \
	  -configuration Debug CODE_SIGNING_ALLOWED=YES build

test-app: generate ## NON-GATING: app test scheme (empty for now)
	cd App && xcodebuild -project Biscotti.xcodeproj -scheme Biscotti \
	  -configuration Debug test

hooks: ## Enable the opt-in pre-commit hook
	git config core.hooksPath .githooks
	@echo "Pre-commit hook enabled (.githooks)."

ci: lint test build ## What the gating CI job runs

clean: ## Remove build artifacts + generated project
	rm -rf .build $(PACKAGES)/.build App/Biscotti.xcodeproj
	rm -rf ~/Library/Developer/Xcode/DerivedData/Biscotti-*
```

> `swiftlint lint` is the explicit form; some versions accept bare `swiftlint`. The coder verifies the installed CLI accepts `--strict`/`--fix` as written and adjusts flags if the pinned version differs.

---

## 5. `Brewfile`

```ruby
brew "xcodegen"
brew "swiftlint"
brew "swiftformat"
# uv (for hooks_mcp/uvx, Phase 2) is already installed outside Homebrew — NOT listed here.
# node (for XcodeBuildMCP/npx) is added in Phase 4.
```

---

## 6. Lint / format config

### `.swiftformat`
```
--swiftversion 6.0
--exclude .build,**/.build,App/Biscotti.xcodeproj,DerivedData
# Deliberate rule choices live here; SwiftFormat is the authoritative formatter.
--self remove
--importgrouping testable-bottom
--commas inline
--trimwhitespace always
```

### `.swiftlint.yml`
```yaml
strict: true
included:
  - Packages
  - App
excluded:
  - .build
  - Packages/BiscottiKit/.build
  - App/Biscotti.xcodeproj
  - "**/DerivedData"

# SwiftFormat owns formatting — disable SwiftLint's overlapping formatting rules
# so the two tools never disagree.
disabled_rules:
  - trailing_comma
  - opening_brace
  - colon
  - comma
  - vertical_whitespace
  - trailing_whitespace
  # sorted_imports conflicts with SwiftFormat's --importgrouping testable-bottom
  # (SwiftLint alphabetizes; SwiftFormat groups @testable at bottom). SwiftFormat
  # is the authoritative formatter, so this rule is disabled here.
  - sorted_imports

# Opt into a stricter set (the author's "stricter ruleset" ask).
# Note: unused_declaration and unused_import are omitted — they require
# `swiftlint analyze` (not `swiftlint lint`) and would silently do nothing
# in our lint pass. Add a separate analyze step if those rules are wanted.
opt_in_rules:
  - force_unwrapping
  - empty_count
  - first_where
  - contains_over_filter_count
  - closure_spacing
  - redundant_type_annotation
  - explicit_init
  - fatal_error_message
  - prefer_self_type_over_type_of_self
```

> **What `opt_in_rules` means:** SwiftLint ships these rules **off by default** (they're stricter / more opinionated); listing them here turns them on — this *is* the "opt into a stricter rule set" ask. Separately, `strict: true` (and `--strict`) makes every violation a non-zero exit (blocking), rather than a mere warning. The opt-in list is a **starting** set, chosen to be high-signal and low-noise on a fresh codebase. It's tuned in review/early use, not frozen.

---

## 7. `.githooks/pre-commit` (executable; opt-in via `make hooks`)

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "› pre-commit: format"
make format
# Re-stage anything formatting changed, so the commit includes the tidied result.
git add -u

echo "› pre-commit: lint"
make lint

echo "› pre-commit: test (swift test — packages only, never xcodebuild)"
make test

echo "✓ pre-commit passed"
```

Blocks the commit on the first failing step (`set -e`). Never runs `xcodebuild`. Speed escape-hatch (move to pre-push) noted in the functional spec.

---

## 8. Agent MCP integration

### `hooks_mcp.yaml` (commands-only; prompts deferred)
```yaml
server_name: "Biscotti"
server_description: "Biscotti dev commands — thin wrappers over the Makefile."

actions:
  - name: "bootstrap"
    description: "Install dev tools via Homebrew (brew bundle)"
    command: "make bootstrap"
  - name: "generate"
    description: "Generate the Xcode project from project.yml"
    command: "make generate"
  - name: "build"
    description: "Build all SPM packages"
    command: "make build"
  - name: "test"
    description: "Gating: run the package test suite (swift test)"
    command: "make test"
  - name: "lint"
    description: "Check formatting + lint (non-mutating)"
    command: "make lint"
  - name: "format"
    description: "Auto-format and autofix lint"
    command: "make format"
  - name: "build_app"
    description: "Non-gating: generate project + build the app (xcodebuild)"
    command: "make build-app"
  - name: "test_app"
    description: "Non-gating: run the app test scheme"
    command: "make test-app"
```

### `.mcp.json` (Claude Code auto-discovers at repo root)
```json
{
  "mcpServers": {
    "hooks-mcp": {
      "type": "stdio",
      "command": "uvx",
      "args": ["hooks-mcp"],
      "env": {}
    },
    "xcodebuildmcp": {
      "command": "npx",
      "args": ["-y", "xcodebuildmcp@latest", "mcp"]
    }
  }
}
```

> **Server key = `hooks-mcp`.** Claude Code derives the tool-name prefix from the server key, so the actions surface as `mcp__hooks-mcp__build`, `…__test`, etc. (as documented in root `CLAUDE.md`). `hooks-mcp` defaults its working directory to cwd, so no `--working-directory` arg is needed.
> **Phasing:** the `hooks-mcp` server (uvx) is added in **Phase 2** — it is the agent command surface that runs `make` targets *outside* the Bash sandbox (which cannot run `swift build`/`xcodebuild`). The `xcodebuildmcp` server (npx) is added in **Phase 4** alongside `node`. So `.mcp.json` is created in Phase 2 with only `hooks-mcp` and gains `xcodebuildmcp` in Phase 4.
> Launch commands per upstream docs (`uvx hooks-mcp`; `npx -y xcodebuildmcp@latest mcp`). The coder verifies both against the current upstream READMEs at build time and pins versions if drift is a concern. `uv` is already installed outside Homebrew; `node` is added to the `Brewfile` in Phase 4.

---

## 9. CI — `.github/workflows/ci.yml`

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:

jobs:
  package-tier:           # GATING — set as the required status check in branch protection
    name: Packages (lint + test)
    runs-on: macos-15      # uses the image's default Xcode (current; Swift 6 toolchain)
    steps:
      - uses: actions/checkout@v4
      - name: Install dev tools
        run: brew bundle --file=Brewfile
      - name: Lint + test + build
        run: make ci

  app-tier:               # NON-GATING — informational only
    name: App build (xcodebuild)
    runs-on: macos-15
    continue-on-error: true
    steps:
      - uses: actions/checkout@v4
      - name: Install dev tools
        run: brew install xcodegen
      - name: Generate + build app
        run: make build-app
```

**Gating model:** only `package-tier` is added to branch protection as a required check (a one-time GitHub repo setting, documented in `CLAUDE.md`). `app-tier` uses `continue-on-error` so its failures show on the PR without blocking merge. **Xcode is left unpinned** — the `macos-15` image's default Xcode is current and ships a Swift 6 toolchain; add a `setup-xcode` step only if a future build needs a specific version.

---

## 10. `.gitignore` (additions)

```
.build/
**/.build/
DerivedData/
App/Biscotti.xcodeproj/
.DS_Store
*.xcuserstate
```

---

## 11. Doc deliverables (edits to existing files)

- **`CLAUDE.md` (root):** add a "Build & checks" section — the Makefile targets and which gate, the two CI tiers, the MCP setup (hooks_mcp primary + XcodeBuildMCP for xcodebuild/run), the locked bundle ID, the `make hooks` opt-in, and that `Packages/`+`App/` now exist. Remove the "not scaffolded yet / no repo-wide check commands" caveats.
- **`specs/research/permissions/README.md`:** change the bundle-ID references from `com.biscotti.app` to `net.scosman.biscotti` (the "Bundle identifier" line in §1/Recommendation and the risk-#5 example), noting it's the locked production ID.

These keep the durable docs truthful per the repo's "when you change things" rule.

---

## 12. Testing strategy

| Tier | What | Framework | Gates? |
|---|---|---|---|
| Package tests | `swift test` on `BiscottiKit` (one trivial Swift Testing case now) | Swift Testing | ✅ |
| Lint/format | `make lint` (swiftformat --lint + swiftlint --strict) | — | ✅ |
| App build | `make build-app` (xcodegen + xcodebuild, ad-hoc) | — | ⚠️ non-gating |
| App tests | none yet (empty scheme) | XCTest/XCUITest later | ⚠️ non-gating |
| Manual launch | build + run once, confirm the placeholder window appears | — | one-time, recorded in the phase notes |

No coverage targets at this stage — there's no logic to cover. The point is that the **harness** itself is green and reproducible.

---

## 13. Error handling & conventions

- **Fail fast, fail loud:** every Make target exits non-zero with a readable message on missing tools or failures; no silent partial success (the pre-commit hook relies on this via `set -euo pipefail`).
- **One command surface:** humans, CI, the pre-commit hook, and hooks_mcp all go through the same Makefile targets — no divergent invocations to drift apart.
- **Generated artifacts are disposable:** the `.xcodeproj` is never hand-edited or committed; `project.yml` is the source of truth and `make generate`/`make build-app` rebuild it.
- **Strict from day one:** Swift 6 language mode + warnings-as-errors on both the package and app, so the codebase never accumulates warning debt.

---

## 14. Build & verification flow (the coder's end-state check)

1. `make bootstrap` → tools install.
2. `make lint` → clean. `make test` → green.
3. `make build-app` → project generates, app builds ad-hoc.
4. Launch the built `.app` → empty window shows "Biscotti" + "BiscottiKit linked". Record this one manual check.
5. `make hooks`; make a dummy lint-violating edit, attempt a commit → hook formats/lints/tests and blocks appropriately.
6. Push a branch → CI: `package-tier` green (required), `app-tier` runs (non-gating).
7. `CLAUDE.md` + `specs/research/permissions` edits landed.
```
