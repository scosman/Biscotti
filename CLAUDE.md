# Biscotti — Repo Guide

Biscotti is a native **macOS meeting recorder**: it records meeting audio (mic + system), produces on-device diarized transcripts, integrates with the calendar, and lives mostly in a menu-bar app. Private, local, Apple-silicon-only (macOS 15+).

**Current stage:** Scaffolding (Project 0) and the **Stage A foundations** are built. Beyond the scaffolding (`BiscottiKit`, `App/`, `Makefile`, `hooks-mcp`, CI, lint/format), the repo now has the `Transcription` and `AudioCapture` packages, the `DataStore` + `ManualTestKit` modules in `BiscottiKit`, the `ManualTestApp` (XcodeGen) that hosts the shared `XPCServices/BiscottiTranscriber.xpc`, and a manual-test CI gate — all green on `lint`/`test`/`build_app`. **The one remaining Stage A step is the human Phase 4.5:** running `ManualTestApp` on real Apple-silicon hardware to fill in the pass/fail results (the non-gating `manual-tests-check` job is RED by design until then). The next *product* step after 4.5 is the MVP (Record → Transcribe). See the roadmap (`implementation_plan.md`).

> This file is a map. Read the specific docs below before acting; don't rely on this summary alone for decisions.

---

## Read this first, by what you're doing

- **Anything at all / new to the repo** → `app_overview.md` (the product) + this file.
- **Designing or building a component, or asking "where does X live / what depends on it?"** → `architecture.md`.
- **Deciding what to build next, scoping a new `/spec` project, or ordering work** → `implementation_plan.md`.
- **Touching audio / calendar / transcription / permissions** → the matching `research/<area>/README.md` (validated decisions — don't re-derive them) **and** the corresponding `experiments/<Name>/` (working reference code).
- **Understanding *why* the design is shaped this way / the rules it follows** → `specs/projects/library_design/functional_spec.md`.

---

## Key files and how they relate

The docs form a chain, each feeding the next:

```
app_overview.md  ─►  research/**  ─►  experiments/**
  (what to build)     (how — proven)    (reference code)
        │                  │                  │
        └──────────────────┴───────► architecture.md ─► implementation_plan.md
                                       (where it lives)    (order to build it)
```

### Product & vision (the "what" and "why")
- **`app_overview.md`** — the master product spec. Every feature, the UX intent, "Misc App Reqs," design style, and the stack/testing philosophy (Swift-package-first, thin app target). **Source of truth for product intent.** Read when you need to know what a feature is supposed to do.
- **`plan.md`** — the high-level staging (Research → Scaffolding → Library Building → App). Short; gives the big-picture sequence. `implementation_plan.md` is the detailed version of this.

### The design — master roadmap (the "where" and "in what order") — at repo root
- **`architecture.md`** — the **static topology**: every component (package vs. module vs. app-glue), its responsibilities (as outcomes, not interfaces), dependency DAG, granularity rationale, thin-app composition, cross-cutting conventions, and P2/P3 placement. **Deliberately shape-level — it designs *no* concrete interfaces/schemas.** Read before building or modifying any component to know its home, boundaries, and dependencies.
- **`implementation_plan.md`** — the **build roadmap**: an ordered list of ~14 Projects (each a future `/spec new project`), with a contents list, dependencies, and risk per Project — but no internal phases (those are decided when each Project is spec'd). Read to pick/scope the next Project. Project 0 (Scaffolding) is the first.

These two were authored in the `library_design` spec project and promoted here to be the durable, living roadmap. Keep them updated as the build progresses.

### Validated research (the "how" — already proven, don't re-litigate)
- **`research/README.md`** — one-page summary of all technical decisions (audio API, format, models, isolation, permissions, distribution) with a recommendations table. Start here for any technical area.
- **`research/audio/README.md`** — audio capture/recording decisions. Plus `research/audio/phase9_validation_findings.md` (what changed after real-hardware validation — e.g. global capture, route-change survival, ADTS AAC) and `research/audio/meeting_app_bundle_ids.md` (seed watchlist data).
- **`research/eventkit/README.md`** — calendar access + the event data-availability report (informs the data model).
- **`research/argmax/README.md`** — WhisperKit + SpeakerKit (STT + diarization): models, XPC isolation, custom vocab, output quirks, centroid embeddings, and the drafted questions for the ArgMax team.
- **`research/permissions/README.md`** — the permissions/entitlements matrix + distribution (non-sandboxed, hardened runtime, Developer ID notarized).

These are the durable knowledge artifacts. **Consume them; don't re-derive their conclusions.** If reality contradicts one, update the doc.

### Reference code — `experiments/` (disposable; productionized later)
Each is an independent, throwaway app/package that proves a technique and leaves reference code. The roadmap's foundation-library Projects productionize these into real `Packages/`.
- **`experiments/AudioLab/`** — Core Audio taps + AVAudioEngine capture/recording, stream monitoring. Seeds `AudioCapture` (+ `Recording`/`MeetingDetection`).
- **`experiments/EventKitLab/`** — EventKit access, filtering, snapshotting, conference-link detection. Seeds `Calendar`.
- **`experiments/ArgMaxKit/`** — SPM library wrapping STT+diarization behind `processAudio`, with a CLI harness. Seeds `Transcription`. (Already an SPM package: `swift build && swift test`.)
- Each ships a **`VALIDATION.md`** — the manual hardware test script that was run; results were folded back into the research docs. Read when productionizing that area.

### Process & planning records — `specs/projects/`
Spec-driven-development artifacts (see the `spec` skill). Mostly historical context.
- **`specs/projects/library_design/`** — how `architecture.md` + `implementation_plan.md` were produced: `project_overview.md` and **`functional_spec.md`** (the design brief: depth contract, design goals, capability catalog). Read `functional_spec.md` to understand the *rules* the architecture follows.
- **`specs/projects/research/`** — the completed research meta-project's specs (overview/functional/architecture/implementation + phase plans). Historical; the *outputs* live in `research/` and `experiments/`.
- **`specs/projects/manual_test_app/`** — a **planned** future project: a manual-test harness app (one tab per library, interactive pass/fail scripts saved to the repo) for hardware/system things unit tests can't cover. Overview only so far; not built.
- **`.specs_skill_state/current_project.md`** — which spec project is active (git-ignored, per-worktree).

---

## Conventions & gotchas

- **Apple Silicon, macOS 15+ only.** Newest APIs are fair game; no Intel/older-macOS support.
- **Swift-package-first.** The app target stays thin (composition root + Apple glue); everything testable lives in packages under `Packages/` so it runs via `swift build`/`swift test` with no `xcodebuild`/signing. See `architecture.md` → "Thin-App Composition."
- **Agents: run builds/tests through the `hooks-mcp` MCP server, not Bash.** The `Makefile` is the canonical command surface, but `swift build`, `swift test`, and `xcodebuild` **fail under the agent Bash sandbox** — llbuild's build-system file writes hit a silent sandbox denial that no SwiftPM flag, scratch-path, or `--disable-sandbox` fixes. The `hooks-mcp` tools (`mcp__hooks-mcp__build`, `…__test`, `…__build_app`, `…__generate`, `…__bootstrap`, etc.) run the *same* `make` targets in the MCP server process, **outside** the sandbox — use them for anything that compiles. Only `mcp__hooks-mcp__lint` / `…__format` (and their `make lint`/`make format` equivalents) are also safe to run directly in Bash — **once the pinned SwiftLint binary is cached under `.tools/`**. On a fresh checkout, `make lint`/`format` first `curl` the pinned SwiftLint (see `SWIFTLINT_VERSION` in the `Makefile`), and that download is blocked by the Bash sandbox; run `mcp__hooks-mcp__lint` (outside the sandbox) once to populate `.tools/`, after which Bash `make lint`/`format` work. Humans and CI invoke `make` directly as usual.
- **The design is shape-level.** When building a component, *you* design its real API inside the boundary `architecture.md` draws — don't expect interfaces there, and don't add them to that doc.
- **Experiments are disposable.** Don't build on them directly; productionize per the roadmap.
- **Building a component = run `/spec new project`** for its roadmap entry; foundation libraries (Transcription, Audio Capture, Data Store) come first.
- **Bundle ID is locked:** `net.scosman.biscotti`. Do not change it (TCC grants persist against it). Signing/notarization are deferred to Project 9.
- **Custom vocabulary is blocked on an upstream SDK bug.** WhisperKit's `promptTokens` API silently blanks the entire transcript for certain term combinations (both turbo and non-turbo models). The AI test for custom vocab is disabled. Do not start product-side custom-vocab work (Project 8's `Vocabulary` module) until the SDK issue is resolved. Tracked: [argmax-oss-swift#489](https://github.com/argmaxinc/argmax-oss-swift/issues/489), [argmax-oss-swift#428](https://github.com/argmaxinc/argmax-oss-swift/pull/428).

---

## Build & checks

### Makefile (the canonical command surface)

All builds, tests, and checks go through the `Makefile`. Humans, CI, the pre-commit hook, and `hooks-mcp` all invoke the same targets.

| Target | Does | Gating? |
|---|---|---|
| `make bootstrap` | Install dev tools via Homebrew (`brew bundle`) + fetch pinned SwiftLint | — |
| `make generate` | Generate `App/Biscotti.xcodeproj` from `App/project.yml` (XcodeGen) | — |
| `make build` | `swift build` all SPM packages | — |
| `make test` | `swift test` across packages | Yes |
| `make test-ai` | Heavy AI/model tests (downloads GBs, runs inference). Developer-run only; agent can't run it — a human runs it via `!`. Not in `test`/`ci`/`precommit-checks`. | Non-gating |
| `make lint` | `swiftformat --lint` + `swiftlint --strict` (non-mutating) | Yes |
| `make format` | Auto-format (SwiftFormat then SwiftLint `--fix`) | — |
| `make precommit-checks` | The pre-commit checks: `format` + `lint` + `test` (hook & `hooks-mcp` both call this) | Yes |
| `make build-app` | `make generate` + `xcodebuild` the app (ad-hoc signed) | Non-gating |
| `make test-app` | App/UI test scheme (empty for now) | Non-gating |
| `make hooks` | Opt-in: point git at `.githooks/pre-commit` | — |
| `make ci` | What the gating CI job runs: `lint` + `test` + `build` | — |
| `make manual-tests-check` | Check all manual-test steps have been run (expected RED until Phase 4.5) | Non-gating |
| `make clean` | Remove `.build/`, `DerivedData/`, generated `.xcodeproj` | — |

### CI (three tiers)

CI pins **Xcode 26.3** via `DEVELOPER_DIR` in `ci.yml` while targeting the **macOS 15 platform** (deployment target). The `macos-15` runner defaults to Xcode 16.4, whose SwiftData SDK lacks `Schema.Version: Sendable` and breaks Swift 6 strict concurrency.

- **`package-tier`** (gating, required check): runs `make ci` (lint + test + build) on `macos-15`. This is the merge gate.
- **`app-tier`** (non-gating, `continue-on-error`): runs `make build-app` on `macos-15`. Reported on the PR for visibility but never blocks merge.
- **`manual-tests-check`** (non-gating, `continue-on-error`): runs `make manual-tests-check` on `macos-15`. Expected RED until Phase 4.5 (when a human runs the manual tests on real hardware). Informational only — never blocks merge.

### Agent command surface (hooks-mcp)

Agents use the `hooks-mcp` MCP server as their primary command surface. It wraps each Makefile target as a named tool: `mcp__hooks-mcp__build`, `mcp__hooks-mcp__test`, `mcp__hooks-mcp__lint`, `mcp__hooks-mcp__format`, `mcp__hooks-mcp__precommit_checks`, `mcp__hooks-mcp__build_app`, `mcp__hooks-mcp__generate`, `mcp__hooks-mcp__bootstrap`, `mcp__hooks-mcp__test_app`, `mcp__hooks-mcp__manual_tests_check`. These run outside the Bash sandbox, which is required for anything that compiles (see the sandbox note above).

**XcodeBuildMCP** is also registered in `.mcp.json` for interactive xcodebuild/run/launch/log operations that a `make` target cannot model.

### Pre-commit & the Claude Code agent

Run `make hooks` once to enable the opt-in hook. It runs `make precommit-checks` (format + re-stage, lint, test) before each commit and blocks on the first failure. Package tests only — never `xcodebuild`.

**Agents cannot run the hook.** Its checks compile Swift, which **fails inside the Claude Code agent sandbox** — an unfixable macOS seatbelt denial (the Swift build-service write of `output-file-map.json` gets `EPERM` even in writable dirs; not redirectable by any env var/flag, same root cause as the `swift build`/`swift test`/`xcodebuild` note in *Conventions & gotchas*). When the hook detects the agent (`CLAUDECODE` is set) it **fails immediately with instructions** instead of emitting confusing "Operation not permitted" noise.

**Agent commit protocol — the only sanctioned use of `--no-verify`:**
1. Run the checks out-of-sandbox: **`mcp__hooks-mcp__precommit_checks`** (wraps `make precommit-checks`).
2. **Only if it passes green**, and with **no code changes since that run**, commit bypassing the hook: `git commit --no-verify …`.

The `precommit_checks` run must be the **last thing before the commit** — if you touch any code after it, re-run it first. Humans and CI are unaffected and commit normally.

---

## When you change things

- Updating product intent → `app_overview.md`. Updating the topology → `architecture.md`. Re-ordering/scoping work → `implementation_plan.md`. Correcting a technical finding → the relevant `research/<area>/README.md`.
- **Manual test staleness rule:** when you touch `Packages/Transcription` or `Packages/AudioCapture`, mark that library's manual tests as `not-run` in `ManualTestApp/Results/manual_test_results.json`. Either hand-edit the file (set `"status": "not-run"` for each step with the matching prefix: `ac_*` for AudioCapture, `tx_*` for Transcription) or use `ResultsStore.markScriptNotRun(scriptID:allStepIDs:)` from `ManualTestKit`. This causes `make manual-tests-check` (and its CI gate) to fail until a human re-runs the affected tests on real hardware and commits the updated results. **Only recordable steps belong in the file** — `.instruction` steps (setup/sequence text the human just reads, e.g. `ac_timed_capture`, `ac_mega_setup`, `ac_crash_safety_setup`) have no pass/fail, are excluded from the gate (`TestStep.isRecordable` / `ResultsStore.recordableStepIDs`), and must not be written back. Pass `recordableStepIDs(in:)` to `markScriptNotRun`, or skip those IDs when hand-editing.

---

## `// TODO` to track future work

Use `TODO` comments to track work we expect to be cleaned up/completed in later phases. Don't just punt work that should be in this phase, but if it's genuinely better to implement later, mark it so we don't miss it.

When code reviewing: allow legit TODOs (legit should be done later), and reject invalid (should be done in this phase).
