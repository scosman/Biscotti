---
status: complete
---

# Functional Spec: Library Design

This project is **architecture, not implementation, and not interface design**. Its output is the *shape* of the Steak codebase: which packages/components exist, what each is responsible for, who depends on whom, and the order to build them. It deliberately stops short of designing any concrete API. Each component's real interface is designed later by the task that builds that component, working inside the boundary this project draws.

See [`/app_overview.md`](../../../app_overview.md) for the product, and [`/research/README.md`](../../../research/README.md) for the already-validated technical findings this design builds on.

## Why This Project Exists

The hard technical unknowns (audio capture, EventKit, on-device transcription, permissions) are already de-risked by the completed `research` project, with reference code in `/experiments/`. What's missing is a **map**: a package/component topology that lets future work proceed in parallel, agent-first, without stepping on each other or discovering the dependency graph the hard way.

The map drives three things:
1. **Parallelism** — well-bounded components can be built independently.
2. **Order** — a dependency graph that dictates what must come before what, front-loading risk so we reach a working app fast.
3. **Testability** — boundaries drawn so the overwhelming majority of the system is testable via `swift test` with no app, simulator, or `xcodebuild`.

## Two Lenses: Structure and Delivery

This project produces two different views, and they must not be conflated:

- **Structure (`architecture.md`)** — the *static, final* topology. Every component that will ever exist, its home and responsibilities, and the dependency edges between them. Drawn **to final** (including P2/P3), so we know where everything slots in.
- **Delivery (`implementation_plan.md`)** — the *dynamic* build order, expressed as an ordered **roadmap of Projects**. Each Project is a future `/spec new project` (its own specing, its own internal phases) — **not** a phase this `library_design` project implements. There is no `/spec implement` step here; the output is the plan that spawns the next projects. A Project typically cuts through *parts* of several components plus the UI a feature needs; components are grown incrementally across Projects, never built to completion in isolation.

  Each roadmap entry lists **what's in the Project** — the components/parts and capabilities it covers, what it delivers, its dependencies, archetype, and risk — but **does not break it into ordered phases**. Phase breakdown is decided when that Project is itself spec'd later.

The static dependency graph constrains the order (you can't depend on what isn't built yet), but Projects are finer-grained than components: a single component may be advanced by several Projects as the features needing it come online.

### Project sizing (the core judgment of this project)

Each roadmap entry is sized so it's a sensible unit of work — not so wide it can't be spec'd cleanly, not so thin it's noise. Two archetypes:

- **Foundation/library Projects** — one complex, critical component built deep (e.g. the transcription library, the audio-recording library). Each gets its **own** Project with many internal phases; never rolled into a broader feature Project (too wide a scope). Validated by tests + a manual test-app/CLI harness (the `/experiments/` pattern) — these are the front-loaded, risk-reducing enablers and do **not** ship a runnable app on their own.
- **Feature/integration Projects** — deliver a self-standing, runnable app increment by wiring already-built components + UI. The first is the MVP (e.g. "record & transcribe app + UI"), runnable once its foundation-library deps land. Subsequent ones layer vertical features (notifications, calendar, search, onboarding, intelligence, …); a smaller feature spans several components but stays a **single** Project with internal phases — not over-subdivided.

**Note:** `architecture.md` and `implementation_plan.md` have been **promoted to the repo root** (`/architecture.md`, `/implementation_plan.md`) as the durable master roadmap. This spec folder keeps the planning record (`project_overview.md`, `functional_spec.md`).

## The Depth Contract

This is the most important rule of this project. **Stay at the shape level.** When in doubt, go shallower.

| IN — this project decides | OUT — the per-component task decides |
|---|---|
| Which components exist and their home (own package / module-in-a-package / app-target glue) | Any concrete API signature, protocol, or type |
| A one-line responsibility + capability bullets, described as **outcomes** | Data model field lists, schemas, enums |
| Dependency edges and their direction | Internal algorithms, threading details, file layout within a package |
| Granularity calls (package vs. module) **with rationale** | Performance/memory tuning specifics |
| Build order and per-component risk flags | Error taxonomies, retry/recovery logic |
| The testability seam (how a component is tested without the app) | The actual tests |

> Example of the right altitude: *"Component X lives in its own package, depends on the data store, must provide [capability A], [capability B], runs isolated from the app process, productionizes `/experiments/<Name>`, and is high deep-dive-risk so it builds early."* — and **stop**. No interface, no signatures, for **any** component.

## Design Goals

These are the standards the topology will be judged against (carried from the project overview):

1. **Testability without the app.** Maximize what runs under `swift build` / `swift test`. Push business logic, view models, navigation, networking, and most UI into packages. The app target is a thin composition root plus irreducible Apple-platform glue (entitlements, App Intents, extensions, asset catalogs) — the things that genuinely can't be unit-tested and need `xcodebuild`/signing.
2. **Dependency graph drives order.** The graph must be a clean DAG (no cycles). It directly produces the build order.
3. **Front-load risk, back-load P2/P3.** Reach a working, end-to-end V1 as fast as possible; everything optional comes after. High deep-dive-risk components are pulled as early as their dependencies allow. **Order matters within V1 too**, not just V1-vs-later: e.g. a minimal record→transcript app should stand on its own before calendar integration exists.
4. **Deliver working increments, not finished components.** From the MVP onward, *every* feature/integration Project leaves a runnable, self-standing app, with each new capability layered onto an already-working app — never horizontal layers ("all backends, then all UI"), never a component built to completion in isolation before it's useful. The only things that precede the first runnable app are the front-loaded foundation-library Projects (validated by tests + harness, like the experiments). "Record→transcript before calendar" is just one instance of the layering rule.
5. **Agent-friendly.** Backend/logic components are validated by unit/integration tests with no human in the loop; humans are needed only at final UI integration and for hardware/system manual validation (the test-app pattern, as used in `/experiments/`).
6. **Idiomatic, quality Swift.** "Great Swift design" — sensible package boundaries, clear ownership, no god-modules. The granularity calls (what's a package vs. a target inside one) are made here, with rationale.

## Capability Catalog

The topology must place **all** of the following. This is the coverage checklist — the architecture maps each capability to a component (one component may cover several). Tags: **[V1]** ships first; **[P2]/[P3]** are later but must have a home in the shape and a place in the order.

### Audio
- **[V1]** Capture mic + system audio as two crash-safe streams (Core Audio process taps + `AVAudioEngine`, per audio research).
- **[V1]** Recording lifecycle: start/stop, stream-to-disk, chosen format, post-recording conversion to long-term storage, cache-dir management, cleanup.
- **[V1]** Meeting/stream detection: watch the process audio list against a known-app watchlist; detect meeting-app audio starting/stopping.
- **[V1]** Track-alignment handling (shared start timestamp; mitigations for start-gap drift).

### Transcription (STT + Diarization)
- **[V1]** Diarized transcript from recorded audio (WhisperKit + SpeakerKit, free SDK).
- **[V1]** Model management: download, cache, delete; disk-space checks; rich status (needs-download, downloading + progress, compiling, loading, running, errors).
- **[V1]** Memory/model lifecycle (load/unload) and crash isolation (XPC service).
- **[V1]** Custom-vocabulary biasing (`promptTokens` workaround).
- **[V1]** Re-transcribe an existing recording (e.g. after fixing event association or vocab).
- **[P2]** Auto speaker identification (signal-based, the audio smarts live here): identify "me" via mic/system stream-timing correlation, and recognize recurring speakers via cross-recording centroid voiceprints. Distinct from, and complementary to, LLM speaker-naming (under Intelligence).

### Calendar
- **[V1]** EventKit full-access; enumerate calendars with include/exclude filtering.
- **[V1]** Snapshot event data (title, participants, organizer, description, times, conferencing info) into our own data model so it survives the EventKit link breaking.
- **[V1]** Conference-link detection (regex over notes/location/url).
- **[P2]** Contacts enrichment (measured but deferred; needs a home).

### Data
- **[V1]** SwiftData model: `Meeting`/`Event` core, attached audio file references, transcript data (versioned — multiple transcripts per meeting), notes, calendar-snapshot sub-item (clearable in one swipe).
- **[V1]** Data utilities/queries; event↔recording association + correction.
- **[V1]** Search across meetings (simple SwiftData term matching for V1).
- **[P2]** iCloud/CloudKit sync of model + audio files.

### Pattern Matching / Remote Config
- **[V1]** Load a server-delivered JSON (bundle ID → app name; URL regexes → meeting platforms); OTA-updatable; matching logic for "is this a meeting app / meeting link."

### Permissions
- **[V1]** Manage mic, system-audio, and calendar permissions: status checks, request flows, denial/re-request handling, the silence-detection pre-check for system audio.

### Notifications
- **[V1]** Meeting-start notification (with join/record actions), ad-hoc-meeting-detected notification, stop-recording countdown notification.

### UI
- **[V1]** Menu-bar/tray app: icon states (idle / next-meeting text / recording), body (recording status, upcoming, recent, open-app, quit).
- **[V1]** App window: sidebar (home, recording indicator, upcoming, past), main area (home, recording view, meeting view), search-takeover.
- **[V1]** Onboarding wizard (permissions, calendar selection, model download, optional demo).
- **[V1]** Settings (calendar selection, custom vocab, launch-on-startup).
- **[P3]** Settings: audio file-usage view + deletion.

### App Lifecycle / Background
- **[V1]** Background-capable app: runs without an open window, can record and render the menu bar.
- **[V1]** Launch-on-startup.
- **[V1]** App composition / navigation / window logic.
- **[P2]** Global configurable keyboard shortcut to start/stop recording.

### Intelligence (LLM) — [P2]
- **[P2]** Summaries, action-item extraction, speaker-name inference, custom-vocab extraction from invites.
- **[P2]** Pluggable providers: local (llama.cpp / Gemma) and external (OpenAI-compatible base URL + key).

### Cross-cutting
- **[V1]** Custom-vocabulary management: app-wide list (settings) + per-meeting merge (participant/company names); **[P3]** per-recording manual additions.

## Relationship to Other Work

- **Builds on `research`** (complete): audio, eventkit, argmax, permissions findings in `/research/`. The topology should not re-litigate those technical choices — it consumes them.
- **Productionizes `/experiments/`**: `AudioLab`, `EventKitLab`, `ArgMaxKit` are reference code. The architecture notes which component each experiment seeds (the `From:` field on a card). Experiments themselves are disposable and not part of the shipped shape.
- **Precedes the build.** Per `plan.md`'s staging (Research → Scaffolding → Library Building → App), this project produces the design and order; the **scaffolding** (CI, lint, format, package skeletons) and the **per-component builds** are later `/spec` projects/tasks. This project creates **no code and no scaffolding.**

## Definition of Done

1. **`architecture.md`** defines every component as a shallow card (home, responsibility, capability outcomes, out-of-scope, dependencies, testability seam, deep-dive risk, source experiment) — and covers **every** capability in the catalog above.
2. A **dependency graph** (clean DAG, layered) and a short **granularity rationale** (package vs. module decisions, with reasons) and the **thin-app composition** (what's left in the app target and why).
3. **`implementation_plan.md`** gives a dependency-driven, risk-front-loaded **roadmap of Projects** — each entry a future `/spec new project`, sized per the archetypes above (foundation-library vs. feature/integration), naming what it delivers and its dependencies. Foundation-library Projects come first (front-loaded risk); from the MVP onward each Project ships a self-standing app increment. Components may be advanced by several Projects.
4. No component is designed below the depth contract — no concrete interfaces anywhere.
5. Interactive review with Steve.

## Out of Scope

- Any concrete API/interface, type, or schema (the whole point).
- Scaffolding, tooling, CI, package skeletons, or any code.
- Re-deriving research decisions already settled in `/research/`.
- Detailed UI/UX design (screen layouts, visual design) — only the *placement* of UI components in the topology.
