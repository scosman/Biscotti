---
status: complete
---

# Architecture: Research

This is a **research project**, so this doc specifies the *scaffolding and process* — repo layout, build tooling, doc templates, experiment skeletons, and the research→coding→validation workflow — not the technical answers. The technical answers are the **outputs** of the research phases and live in `/research/<area>/` docs. Where this doc gives an API or model choice, treat it as a **starting point the research may revise**, not a fixed decision.

## Principles

- **Defer technical bets to research docs.** Coding phases read the relevant `/research/<area>/` doc and implement its recommendation. They do not re-derive choices.
- **Experiments are disposable.** Favor the simplest thing that proves the technique and leaves good reference code. Lighter test bar — except ArgMaxKit, which may graduate to a real library.
- **Batched phases.** All research → all coding → all validation (per project decision). Validation never blocks coding.

## Repository Layout

```
/                      (repo root)
├── app_overview.md
├── research/                      # research outputs (decision docs)
│   ├── README.md                  # top-level summary + links (written last)
│   ├── audio/README.md            # R1
│   ├── eventkit/README.md         # R2
│   ├── argmax/README.md           # R3 (incl. isolation & lifecycle)
│   └── permissions/README.md      # R4
├── experiments/                   # disposable reference apps/libs
│   ├── AudioLab/                  # E1  XcodeGen macOS app
│   ├── EventKitLab/               # E2  XcodeGen macOS app
│   └── ArgMaxKit/                 # E3  SPM library + CLI harness
└── specs/projects/research/       # this spec
```

Each experiment is **independent** (own project/package), so one can be thrown away without touching the others.

## Build Tooling & Conventions

- **Swift 6.2 / Xcode 26.3, target arm64 macOS 15.0.** Strict concurrency on (Swift 6 default).
- **UI experiments (AudioLab, EventKitLab):** scaffolded with **XcodeGen** — a checked-in `project.yml` generates the `.xcodeproj`. The `.xcodeproj` is **git-ignored**; regenerate with `xcodegen generate`. This keeps the source of truth diffable and agent-friendly.
- **Library experiment (ArgMaxKit):** plain **Swift Package Manager** (`Package.swift`) — a library product + an executable CLI harness target. Depends on `argmax-oss-swift` via SPM.
- **Code signing:** **ad-hoc** (`CODE_SIGN_IDENTITY = "-"`, `CODE_SIGN_STYLE = Manual`, `CODE_SIGNING_REQUIRED = NO` where needed). Stable `PRODUCT_BUNDLE_IDENTIFIER` per app (`com.biscotti.experiments.<name>`) so TCC permission grants persist across rebuilds.
- **Sandbox:** experiments run **non-sandboxed** (no App Sandbox entitlement) to keep TCC/permission testing simple. Notarization/sandbox implications for the *real* app are an R4 research deliverable, not an experiment requirement.

### Automated Checks (run by coding agents before "ready for CR")

There is no repo-wide CLAUDE.md yet, so the checks are defined here:

- **XcodeGen apps:** `cd experiments/<Name> && xcodegen generate && xcodebuild -project <Name>.xcodeproj -scheme <Name> -destination 'platform=macOS' build`
- **SPM package (ArgMaxKit):** `cd experiments/ArgMaxKit && swift build && swift test`
- A clean build (no warnings introduced) + passing tests is the bar. UI/permission behavior that can't be unit-tested is deferred to the validation phase, not faked.

## Research Workflow

Each research phase spawns a research sub-agent that:

1. Reads the relevant section of `functional_spec.md` (the key questions for its area).
2. Investigates: web search, official Apple docs, the `argmax-oss-swift` source/model library, reference projects (AudioCap, AudioTee).
3. Writes `/research/<area>/README.md` using the template below.
4. Returns a short summary.

Research agents **do not write experiment code** — they produce knowledge + recommendations the coding phases consume.

### Research Doc Template (`/research/<area>/README.md`)

```markdown
# <Area> Research

## Summary
One paragraph: the recommendation, in plain terms.

## Key Questions & Findings
For each key question from the functional spec: the question, what we found,
sources/links. Be concrete (API names, settings, numbers).

## Recommendation
The concrete approach the experiment/app should implement: chosen API, settings,
data shapes, code sketch if useful.

## Risks & Gotchas
Known failure modes and mitigations.

## Open Questions for the Team
Genuine choices to send to the ArgMax folks / revisit at app-design time.
(ArgMax doc additionally drafts a "confirm this approach sounds good" summary.)
```

## Experiment Designs

### E1 — AudioLab (`experiments/AudioLab/`)

XcodeGen macOS SwiftUI app implementing R1's recommended audio API.

- **Two views/tabs:** *Streams* (live list of audio streams starting/stopping with source-app identifiers + metadata the API exposes) and *Record* (start/stop recording to disk in the recommended format, surfacing file path/size/duration).
- **Info.plist:** `NSAudioCaptureUsageDescription`, `NSMicrophoneUsageDescription` (exact keys finalized by R1/R4).
- **Structure:** a thin SwiftUI layer over an `AudioEngine`/capture type that encapsulates the chosen API, so the reusable logic is separable from UI.
- Minimal tests where they help (e.g. format/encoder config); system capture is validated manually (V1).

### E2 — EventKitLab (`experiments/EventKitLab/`)

XcodeGen macOS SwiftUI app implementing R2.

- Request calendar access (full-access flow); list calendars with include/exclude toggles; list events from selected calendars showing title/participants/organizer/description/times/conferencing info.
- A **"Dump data report"** action that prints/exports every useful field EventKit exposes (feeds the core app's Meeting model design). The report content is also folded into `/research/eventkit/README.md`.
- **Info.plist:** `NSCalendarsFullAccessUsageDescription` (finalized by R2/R4).
- No library wrapper — proof-of-concept + reference code.

### E3 — ArgMaxKit (`experiments/ArgMaxKit/`)

SPM package: a `ArgMaxKit` **library** + an `argmaxkit-cli` **executable harness**. Higher test bar.

- **Library API (preliminary — finalized from R3):**

  ```swift
  public struct TranscriptResult: Sendable, Codable {
      // Rich capture of whatever the SDK returns. Shape finalized by R3.
      // e.g. segments with start/end, speakerID, text, word timings, confidence.
  }

  public actor ArgMaxProcessor {
      public init(config: ProcessorConfig) async throws   // model selection, vocab
      public func processAudio(_ file: URL) async throws -> TranscriptResult
      // load/unload hooks if R3 finds them necessary for the memory lifecycle
  }
  ```

  - Runs STT (Parakeet V3) + diarization (sortformer-v2-1) — **pending R3 confirmation** these load on the free SDK; R3 picks the best free alternative if not.
  - Runs in the **isolated worker** chosen by R3 (XPC service / subprocess / background actor) so a crash or memory spike can't take down a host app. The CLI harness exercises the same isolation path.
  - Accepts a **custom vocabulary** list per R3's findings.
- **CLI harness:** `argmaxkit-cli <audio-file>` → loads models, runs `processAudio`, prints the rich `TranscriptResult` (JSON) for inspection. No TCC permissions needed (on-device CoreML), so a CLI is sufficient and easily testable.
- **Tests:** unit/integration around the API surface and output shape, using a short bundled sample clip. Test that the result decodes, has expected fields, and speaker turns are present.

## Validation (manual scripts — end of project)

Each experiment ships `experiments/<Name>/VALIDATION.md`: a numbered script the **user** runs once on real hardware; the agent writes it, the human clicks/confirms, and results are recorded back into the matching `/research/<area>/README.md`. Covers V1 (audio), V2 (eventkit), V3 (argmaxkit) per the functional spec.

## Error Handling & Testing Strategy (summary)

- **Experiments:** surface errors visibly in-UI / in CLI output; no silent failures. Since these are disposable, error handling is "clear and debuggable," not "production-graceful."
- **Tests:** SPM `swift test` for ArgMaxKit (the only area with a real test bar); XcodeGen apps build clean and rely on manual validation for system integration.
- **Research docs** are the durable artifact — they must stand alone for whoever designs the core app next.

## Component Designs

Not needed — this single architecture doc plus the per-area research docs (generated during implementation) fully cover the design. No `/components/` step.
