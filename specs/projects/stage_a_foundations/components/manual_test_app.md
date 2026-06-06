---
status: draft
---

# Component: Manual Test App (`ManualTestApp/` + `ManualTestKit` + `BiscottiTranscriber.xpc`)

The durable manual-test harness from [`manual_test_app/project_overview.md`](../../manual_test_app/project_overview.md). A macOS app (its own XcodeGen project at repo root, peer to `App/`) that makes the hardware/system behavior of Transcription and Audio Capture human-checkable, records results in the repo, and **hosts the real `BiscottiTranscriber.xpc` service** (decided) so Stage A retires the XPC + CoreML isolation risk.

This is the only part with UI; its UI shape is covered here (no separate `ui_design.md`).

## Purpose & Scope

**In:** an interactive, scripted test runner with one tab per hardware/system library (**Transcription, Audio Capture** — no DataStore tab); a checked-in pass/fail/not-run results file; a CI gate that every test is marked run; the CLAUDE.md staleness convention; the `BiscottiTranscriber.xpc` service bundle linking the Transcription package.

**Not:** automating the human checks; a DataStore tab; signing/shipping; product UI.

## Public Interface

### `ManualTestKit` (a `BiscottiKit` module — the swift-testable harness logic)

```swift
public enum TestStep: Sendable, Identifiable {
    case action(id: String, label: String, run: @Sendable () async throws -> Void)
    case instruction(id: String, text: String)
    case humanQuestion(id: String, prompt: String)             // → yes/no + optional note
    case autoCheck(id: String, label: String, check: @Sendable () async -> CheckOutcome)
    public var id: String { get }
}

public struct CheckOutcome: Sendable, Equatable {
    public let passed: Bool
    public let detail: String
}

public struct TestScript: Sendable, Identifiable {
    public let id: String           // e.g. "audio_capture"
    public let title: String
    public let steps: [TestStep]
}

public enum TestStatus: String, Codable, Sendable { case pass, fail, notRun = "not-run" }

public struct TestResult: Codable, Sendable, Equatable {
    public let stepID: String
    public var status: TestStatus
    public var note: String?
    public var timestamp: Date?
}

/// Reads/writes the checked-in results file; merges new runs over existing entries.
public struct ResultsStore: Sendable {
    public init(fileURL: URL)
    public func load() throws -> [String: TestResult]
    public func record(_ result: TestResult) throws
    public func markScriptNotRun(scriptID: String, allStepIDs: [String]) throws  // for the staleness convention
    public func allStepIDs(in scripts: [TestScript]) -> [String]
    public func unrun(in scripts: [TestScript]) throws -> [String]               // CI gate uses this
}
```

The script *content* (the actual steps for each library) is defined as `TestScript` values in `ManualTestKit` so they are unit-tested for shape; the app renders them.

### App structure (`ManualTestApp/`, thin SwiftUI shell)

- A `TabView` with one tab per `TestScript`.
- A generic **script runner view** that walks a `TestScript`'s steps in order: renders each step by case (button / instruction text / yes-no question / auto-check with live result), and writes each outcome through `ResultsStore`.
- Holds the `Transcriber(backend: .hosted(serviceName: "…BiscottiTranscriber"))` and an `AudioRecorder` to drive the action/auto-check closures.
- Tabs show per-step status badges loaded from the results file.

### `BiscottiTranscriber.xpc` (shared glue, declared as a target here)

The real `.xpc` bundle: glue source (`main.swift` entry point, Info.plist, entitlements — audio-input, non-sandboxed) lives **once** in `XPCServices/BiscottiTranscriber/` and links the `Transcription` package's worker behind the `@objc TranscriberServiceProtocol`. `ManualTestApp/project.yml` declares the `.xpc` target with `sources: [../XPCServices/BiscottiTranscriber]`. **This is reused, not reimplemented, in Project 4:** `App/project.yml` later declares the same target against the same shared files; only the ~15-line YAML stanza repeats (an Xcode target can't span two projects). No code is rewritten.

## UI shape

```
┌───────────────────────────────────────────────┐
│  [ Audio Capture ] [ Transcription ]           │  ← tabs (one per script)
├───────────────────────────────────────────────┤
│  Audio Capture — manual test plan              │
│                                                │
│  ① ▶ Request permissions            [Run]      │  action
│  ② Did you see TWO dialogs (mic+sys)? [Y] [N]  │  humanQuestion + note
│  ③ Speak & play system audio for 15s           │  instruction
│  ④ ✓ Two files exist, sizes sane     [pass]    │  autoCheck (live)
│  ⑤ Play files — was quality good?    [Y] [N]   │  humanQuestion
│  ⑥ Disconnect AirPods mid-record…    [Y] [N]   │  route-change check
│                                                │
│  Status: 4 pass · 0 fail · 2 not-run           │
└───────────────────────────────────────────────┘
```

## Test scripts (content, from the experiment `VALIDATION.md` files)

- **Audio Capture:** request permissions → confirm two dialogs → timed two-stream capture → auto-check two `.m4a` exist with sane sizes → playback quality (mic? system?) → route-change-mid-recording (AirPods) → monitoring lists the active meeting app.
- **Transcription:** model download (progress + disk check) → transcribe a recorded clip **over the real XPC service** → auto-check diarized output has ≥2 speakers and **no segment past audio length** → **crash-isolation**: kill the worker mid-run, confirm host survives and a retry succeeds → custom-vocab bias spot-check.

## Results file, CI gate, CLAUDE.md convention

- **File:** `ManualTestApp/Results/manual_test_results.json`, checked in. `{ stepID: TestResult }`. The app merges new runs; humans commit the updated file.
- **CI gate:** a script (run in the gating CI tier, e.g. `make manual-tests-check`) loads the file and the known step IDs and fails if any is `not-run` or missing. CI never executes the tests — it only verifies the file claims completion.
- **CLAUDE.md convention:** add a rule — *when you touch `Packages/Transcription` or `Packages/AudioCapture`, run `ResultsStore.markScriptNotRun` for that library (or hand-edit the results file) so its manual tests show `not-run`*; the CI gate then forces a re-run before merge.

## Dependencies

`Transcription`, `AudioCapture`, `ManualTestKit` (+ `DataStore` only if a script needs to persist — not required). Builds on the **non-gating app tier** (`build_app`). The `.xpc` links `Transcription`.

## Test Plan

`swift test` on `ManualTestKit` (the app shell + live runs are human-only):
- `ResultsStoreTests` — load empty; record overwrites; `markScriptNotRun` sets all steps to `not-run`; `unrun` returns exactly the not-run/missing IDs.
- `ScriptShapeTests` — both scripts have unique, stable step IDs; every step id is non-empty.
- `CIGateTests` — given a results file with one `not-run`, the gate logic reports failure; all-pass reports success.
- `CheckOutcomeTests` — the file-existence/size and "no segment past duration" auto-checks return expected outcomes against fixtures.

**Build check (automated, non-gating):** `make build-app` for `ManualTestApp` (incl. the `.xpc`) is green.
**Human-only (the final phase):** actually running every script on real hardware and committing an all-`pass`/`fail` results file.
</content>
