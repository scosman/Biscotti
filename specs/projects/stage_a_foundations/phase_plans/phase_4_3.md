---
status: complete
---

# Phase 4.3: BiscottiTranscriber.xpc service + hosted wiring

## Overview

Create the **shared** XPC service glue in `XPCServices/BiscottiTranscriber/` (repo root) that wraps `InProcessTranscriptionEngine` behind `TranscriberServiceProtocol`, declare the `.xpc` target in `ManualTestApp/project.yml` and embed it in the app, then switch the Transcription tab wiring from `.inProcess` to `.hosted(serviceName:)`.

**Phase boundary:** the XPC service builds and embeds; the client-side adapter (`XPCEngineAdapter`, `TranscriberXPCConnectionImpl`) already exists from Phase 1.3. No new tests required (the `.xpc` is exercised by the human phase 4.5).

## Steps

1. **Make `XPCProcessRequest` public** — change access level from `internal` to `public` in `Packages/Transcription/Sources/Transcription/XPCProcessRequest.swift` so the XPC service target (which links the Transcription package as a dependency) can decode incoming request payloads.

2. **Create `XPCServices/BiscottiTranscriber/` directory** with three files:

   - **`main.swift`** — `NSXPCListener.service()` entry point with an `NSXPCListenerDelegate` that vends a `ServiceDelegate`-created exported object. The exported object conforms to `TranscriberServiceProtocol` and bridges each `@objc` reply-handler method to the async `InProcessTranscriptionEngine` calls via `Task`.

   - **`Info.plist`** — XPC service bundle plist: `CFBundleIdentifier` = `net.scosman.biscotti.BiscottiTranscriber`, `CFBundlePackageType` = `XPC!`.

   - **`BiscottiTranscriber.entitlements`** — non-sandboxed (`com.apple.security.app-sandbox` = false) + audio-input (`com.apple.security.device.audio-input` = true), mirroring the host app.

3. **Update `ManualTestApp/project.yml`** — add a `BiscottiTranscriber` target of type `xpc-service`, sourced from `../XPCServices/BiscottiTranscriber`, with a dependency on the `Transcription` package product, and embed it in the `ManualTestApp` target via a `target: BiscottiTranscriber` dependency with `embed: true`.

4. **Update `ManualTestApp/Sources/WiredScripts.swift`** — change `Transcriber(backend: .inProcess)` to `Transcriber(backend: .hosted(serviceName: "net.scosman.biscotti.BiscottiTranscriber"))`.

5. **Update `Makefile`** — add `XPCServices` to `LINT_PATHS` so the new Swift source is covered by format/lint.

6. **Update `ManualTestApp/project.yml` scheme** — ensure the scheme builds both targets.

## Done when

- `mcp__hooks-mcp__build_app` builds ManualTestApp + embedded `.xpc` GREEN.
- `mcp__hooks-mcp__test` stays green (no package-level changes except the access-level bump).
- `mcp__hooks-mcp__lint` passes with `XPCServices` included.
