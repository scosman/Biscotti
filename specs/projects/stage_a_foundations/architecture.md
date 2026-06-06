---
status: draft
---

# Architecture: Stage A Foundations

This project designs **four separable units**, each in its own component doc. Unlike the repo [`architecture.md`](../../../architecture.md) (which is deliberately *shape-level* — homes, boundaries, dependency edges, no interfaces), **these component docs go deep**: they design the real public API (types and signatures) inside the boundaries the repo architecture already drew. That is the explicit ask for parts 1 & 2 ("packaging, testing, and API-design exercise").

This top-level doc holds only what is **shared across the four**: the workspace additions, the resolved cross-cutting technical choices, the dependency picture for Stage A, and the autonomy/test-seam strategy. Everything component-specific lives in:

- [`components/transcription.md`](components/transcription.md) — Part 1, `Packages/Transcription`.
- [`components/audio_capture.md`](components/audio_capture.md) — Part 2, `Packages/AudioCapture`.
- [`components/data_store.md`](components/data_store.md) — Part 3, `DataStore` module in `BiscottiKit`.
- [`components/manual_test_app.md`](components/manual_test_app.md) — Part 4, `ManualTestApp/` Xcode project (+ `ManualTestKit` module + the `BiscottiTranscriber.xpc` service).

**No separate `ui_design.md`.** The only UI is the utilitarian Manual Test App; its screen/UI shape is covered inside its component doc.

---

## 1. Workspace additions (what Stage A creates)

```
/
├── Packages/
│   ├── BiscottiKit/                      # existing — gains the DataStore + ManualTestKit targets
│   │   └── Sources/
│   │       ├── DataStore/                # NEW (Part 3)
│   │       └── ManualTestKit/            # NEW (Part 4 — testable harness logic: scripts + results file)
│   ├── AudioCapture/                     # NEW package (Part 2)
│   │   ├── Package.swift
│   │   ├── Sources/AudioCapture/
│   │   └── Tests/AudioCaptureTests/
│   └── Transcription/                    # NEW package (Part 1)
│       ├── Package.swift                 # depends on argmax-oss-swift
│       ├── Sources/Transcription/        # library: client, models, vocab, sanitization, in-proc worker
│       ├── Sources/transcribe-cli/       # CLI harness (in-process path)
│       └── Tests/TranscriptionTests/
├── XPCServices/
│   └── BiscottiTranscriber/              # SHARED .xpc glue source (main.swift entry point,
│                                         #   Info.plist, entitlements) — links the Transcription
│                                         #   package. Declared as an .xpc target by ManualTestApp
│                                         #   now, and by App/ later, both pointing at THESE files.
└── ManualTestApp/                        # NEW XcodeGen project (Part 4), peer to App/
    ├── project.yml                       # declares the app target + the .xpc target (sources → ../XPCServices/BiscottiTranscriber)
    ├── Sources/                          # thin SwiftUI app shell; tabs host ManualTestKit scripts
    ├── Resources/Info.plist              # mic + system-audio + (no calendar) usage strings
    ├── ManualTestApp.entitlements        # audio-input; non-sandboxed
    └── Results/manual_test_results.json  # checked-in results file (read/written by the app)
```

`Transcription` and `AudioCapture` are their own packages (engine isolation + their own harnesses + heavy/risky deps — the three reasons in repo architecture). `DataStore` and `ManualTestKit` are cheap module targets inside `BiscottiKit`.

**The `.xpc` service is reused, not reimplemented, in Project 4.** Its substantive logic is the Transcription package's worker (reused verbatim — it's a package). Its glue source (`main.swift`, Info.plist, entitlements) lives once in `XPCServices/BiscottiTranscriber/`. `ManualTestApp/project.yml` declares an `.xpc` target whose sources point at that shared dir; in Project 4, `App/project.yml` declares the **same** target against the **same** files. Only the per-project XcodeGen target stanza (~15 lines of YAML) is duplicated — an Xcode target can't span two `.xcodeproj` files, so that much is irreducible. No code is rewritten.

---

## 2. Resolved technical choices (no decisions left for the coder)

| Area | Decision | Source |
|---|---|---|
| Transcription package tools version | `swift-tools-version: 6.0` (argmax-oss-swift v1.0.0 requires 6.0), `swiftLanguageModes: [.v6]`, warnings-as-errors via `-warnings-as-errors` unsafeFlag | matches `experiments/ArgMaxKit/Package.swift` + scaffolding |
| AudioCapture / DataStore / ManualTestKit | match `BiscottiKit` manifest (`6.1` tools, `.v6` mode, warnings-as-errors) | scaffolding |
| STT model | `openai_whisper-large-v3_turbo`; **quantized `_turbo_1307MB` is the default in tests** (reproducible, 8 GB-safe); full-precision opt-in | research/argmax §2 |
| Diarization model | Pyannote v4 community-1 via SpeakerKit (~33 MB); MAY be bundled | research/argmax |
| Merge for SDK | merge mic+system to **mono 16 kHz `[Float]`** in Transcription; retain stream labels | research/argmax §5 |
| Capture: system audio | **global** Core Audio process tap (`stereoGlobalTapButExcludeProcesses`) + aggregate device (distinct UID, default-output sub-device, `isPrivate`) — not per-process | phase9 #3 |
| Capture: mic | **plain `AVAudioEngine`** input-node tap (NOT VPIO); client format = mono processing format; frame count ÷ channelCount (M-series mic is a 3-ch beamforming array) | phase9 #1 |
| Record format | **record ADTS AAC directly** via `ExtAudioFile` + `kAudioFileAAC_ADTSType` — AAC-LC **mono, 24 kHz, 64 kbps**, `.aac` files; self-syncing → crash-safe with **no finalization**. **No CAF, no PCM scratch, no encode-on-stop.** Bitrate via `AudioConverter` + NULL-`CFArrayRef` `ConverterConfig` commit | **phase9 #5 RESOLVED** |
| Route-change survival | **file-preserving**: keep the same `ExtAudioFile` open across mic `AVAudioEngineConfigurationChange` (re-query format, reinstall tap, restart) and system output-device rebuild | phase9 #2 |
| Zero-buffer RMS monitor | keep in place, **unwired** by default | phase9 Test 7 |
| Permission check | **mic:** definitive `AVCaptureDevice.authorizationStatus` preflight (refuse-to-start on denied); **system audio:** zero-buffer heuristic in first ~2 s (no public API), deferred/unwired | phase9 Test 4 / research/permissions |
| Live monitoring | push-based per-process `kAudioProcessPropertyIsRunning` listeners (NOT `IsRunningInput/Output` — no notifications), reconciled against the process list | phase9 #8 |
| XPC host (Stage A) | the **Manual Test App** hosts `BiscottiTranscriber.xpc`; Transcription also offers an **in-process actor fallback** | decided / research/argmax §7 |
| DataStore container | configurable; **in-memory for tests**; CloudKit option wired-but-off | architecture §4 |
| Manual-test results | checked-in JSON; CI gate on "all marked run"; CLAUDE.md staleness convention | decided / manual_test_app overview |
| DataStore manual tab | **none** — DataStore is unit-test-only | decided |

---

## 3. Stage A dependency picture

```
Transcription (pkg) ──┐
AudioCapture (pkg) ────┤
DataStore (BiscottiKit)┘   ← three mutually-independent foundations (each needs only Scaffolding)
        │  │  │
        ▼  ▼  ▼
   ManualTestApp (Xcode project)
     ├─ ManualTestKit (BiscottiKit module: scripts + results — swift-testable)
     └─ BiscottiTranscriber.xpc (links Transcription)
```

Parts 1, 2, 3 are independent and could be built in any order / in parallel; Part 4 depends on all three (it imports their APIs and hosts the XPC service). The implementation plan serializes them risk-first (Transcription → Audio → DataStore → Manual Test App) but nothing forces that beyond risk-retirement.

The repo DAG is unchanged — no new cross-package edges among the three foundations; `ManualTestApp` is a new leaf consumer that mirrors how `App` will consume them later.

---

## 4. Autonomy & test-seam strategy (how the run stays human-free until the end)

Every component is built behind seams so its logic is `swift test`-able with **no hardware, no live models, no prompts, no disk**:

- **Transcription:** the WhisperKit/SpeakerKit worker sits behind a protocol; tests use a stub worker + a small bundled fixture clip for the in-process path. Sanitization, vocab formatting, merge/label handling, status state machine, error mapping, and result encoding are all pure and unit-tested. The CLI runs the in-process path. **Live model download, real XPC, CoreML, memory pressure → Manual Test App only.**
- **AudioCapture:** Core Audio / AVAudioEngine / TCC behind seams; tests feed synthetic PCM buffers and synthetic process-activity streams; encoder-settings, RMS, frame-count, file-manager, and process-listener logic are unit-tested (these already exist as tests in `AudioLab`). **Real mic/system capture, route changes, quality, permission dialogs → Manual Test App only.**
- **DataStore:** entirely unit-tested against an in-memory container.
- **ManualTestApp:** the harness *logic* (script model, step sequencing, results read/write/serialize) lives in `ManualTestKit` and is unit-tested; the app shell + `.xpc` build green on the **non-gating app tier** automatically; only their *execution* needs a human.

So the build agent can take every phase to green via `hooks-mcp` (`test` gating; `build_app` non-gating for the app phases), and the final phase is the lone human step.

---

## 5. Component-doc index

Each component doc follows the same structure: **Purpose & Scope · Public Interface (real signatures) · Internal Design · Dependencies · Test Plan.** Read the four docs for the actual designs; this doc is only the shared frame.
</content>
