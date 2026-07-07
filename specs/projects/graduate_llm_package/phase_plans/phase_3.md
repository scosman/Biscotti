---
status: complete
---

# Phase 3: XPC Host + ManualTestApp Tab + Docs

## Overview

Build the `BiscottiLLM.xpc` service host, integrate it into ManualTestApp (project.yml + LocalLLM tab), add the `llm_*` manual test steps, and update root documentation. This completes the build-time integration; the human hardware run is Phase 4.

## Steps

### 1. XPC service host files (`XPCServices/BiscottiLLM/`)

Create three files mirroring `XPCServices/BiscottiTranscriber/`:

- **`main.swift`**: `LLMXPCService` (exported object wrapping an in-process `LLMConnection` via a `ConnectionHolder` actor), `ConnectionCounter`, `ServiceDelegate` (listener delegate with connection counting and `_exit(0)` reclamation), and the entry point (`NSXPCListener.service()`). Mirrors BiscottiTranscriber but bridges `LLMServiceProtocol`/`LLMEventReporting` and uses `LLMConnection` for inference.
- **`Info.plist`**: `CFBundleIdentifier = net.scosman.biscotti.BiscottiLLM`, `CFBundlePackageType = XPC!`, `XPCService = { ServiceType = Application }`.
- **`BiscottiLLM.entitlements`**: `com.apple.security.app-sandbox = false` (no audio entitlement needed for LLM).

### 2. ManualTestApp `project.yml` changes

- Add `LocalLLM` to `packages:` (path: `../Packages/LocalLLM`).
- Add `BiscottiLLM` xpc-service target mirroring `BiscottiTranscriber`.
- Add `LocalLLM` package dependency and `BiscottiLLM` target dependency (`embed: true`) to `ManualTestApp` target.

### 3. LocalLLM manual test script (`LocalLLMScript.swift`)

Add `Scripts/LocalLLMScript.swift` in ManualTestKit with `TestScript.localLLM` containing the `llm_*` steps from the functional spec. Register in `AllScripts.swift`.

### 4. WiredScripts integration (`wireLocalLLM`)

Add `case "local_llm": wireLocalLLM(script)` to `WiredScripts.all()`. Wire the action steps: `llm_model_download` (in-process `ModelDownloader`), `llm_xpc_inference` (real XPC via `.hosted(serviceName:)`). Wire the autoCheck `llm_reclamation` (process enumeration check).

### 5. AutoChecks: LLM reclamation check

Add `checkNoLLMServiceRunning()` to `AutoChecks.swift` using `Process` to run `pgrep -x BiscottiLLM`.

### 6. Results JSON: seed `llm_*` not-run entries

Add all recordable `llm_*` step IDs to `manual_test_results.json` with `"status": "not-run"`.

### 7. Update ScriptShapeTests and CIGateTests

- Add `localLLMIdentity`, `localLLMStepCount`, `localLLMStepIDs`, `localLLMInternalUniqueness` tests.
- Update `allScriptsContainsBoth` to `allScriptsContainsAll` (now 3 scripts).
- Update `allStepIDsUnique` to include LocalLLM steps.
- Update `resultsFileCoversAllStepIDs` expected recordable count.

### 8. Documentation updates

- `specs/architecture.md`: update the Intelligence component card and workspace layout to note `Packages/LocalLLM` exists as a graduated package with `BiscottiLLM.xpc`.
- `specs/implementation_plan.md`: note the NSXPC transport is built ahead of Project 10.
- Root `CLAUDE.md`: add `Packages/LocalLLM` and `XPCServices/BiscottiLLM` to the repo map; extend the staleness rule with `llm_*`/`Packages/LocalLLM`.
- `Packages/LocalLLM/README.md`: update to reflect the XPC backend is now built.

## Tests

- ScriptShapeTests: LocalLLM script identity, step count, step IDs, internal uniqueness.
- CIGateTests: Updated recordable step count covering all three scripts.
- All step IDs across all scripts remain unique.
- `allScripts` count updated from 2 to 3.
- `make ci` green; `make build-app` green; `manual-tests-check` reports `llm_*` not-run.
