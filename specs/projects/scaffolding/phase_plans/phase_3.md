---
status: complete
---

# Phase 3: Thin App Target via XcodeGen

## Overview

Adds the macOS app shell built from a checked-in XcodeGen manifest (`project.yml`). The app links `BiscottiKit`, renders its marker in a placeholder window, and is ad-hoc signed for local dev/CI. Makefile gains `generate`, `build-app`, and `test-app` targets.

## Steps

1. Create `App/project.yml` — XcodeGen manifest with bundle ID `net.scosman.biscotti`, ad-hoc signing, Swift 6 + warnings-as-errors, BiscottiKit local package dependency.
2. Create `App/Sources/BiscottiApp.swift` — `@main` SwiftUI App with a single `WindowGroup` rendering `BiscottiKit.marker`.
3. Create `App/Resources/Info.plist` — usage strings for mic, system audio, and calendar.
4. Create `App/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` — empty placeholder app icon.
5. Create `App/Biscotti.entitlements` — `com.apple.security.device.audio-input` entitlement.
6. Update `Makefile` — the `generate`, `build-app`, `test-app` targets (and `.PHONY`) **already exist** (added during the Phase 2 Makefile work; `build-app`/`test-app` already use `xcodebuild -quiet -destination 'platform=macOS,arch=arm64'` to bound output). Verify they are correct and functional now that `App/` exists; only adjust if needed.
7. Run `make format` + `make lint` to verify the new Swift source is clean.
8. Run `make build-app` to verify xcodegen + xcodebuild work end-to-end.
9. Run `make test` to verify existing package tests still pass.

## Tests

- No new automated tests in this phase (the app shell has no logic to test; the app test scheme is empty). Package tests (`make test`) must remain green.
- Build verification: `make build-app` succeeds (xcodegen generates the project, xcodebuild builds ad-hoc).
- Lint verification: `make lint` passes on the new `App/Sources/` code.
