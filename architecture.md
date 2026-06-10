---
status: complete
---

# Architecture: Biscotti Codebase Topology

This is the **static, final shape** of the Biscotti codebase — every component that will exist (V1 and later), where it lives, what it's responsible for, and how the dependencies flow. It is drawn *to final* so we know where everything slots in.

**Read this with the depth contract from the [functional spec](specs/projects/library_design/functional_spec.md):** components are described at the *shape* level — home, responsibility, capability **outcomes**, boundaries, dependencies, testability seam, risk. **No concrete interfaces, types, or schemas appear here, for any component.** The task that builds a component designs its real API inside the boundary drawn here.

Delivery order (which Projects build what, and when) is the separate concern of [`implementation_plan.md`](implementation_plan.md).

---

## Granularity Decision (the call you asked me to make)

**Recommendation: a small number of Swift packages, each holding many focused module targets — not one package, and not a package per component.**

The expensive unit of coordination in SPM is the **package** (its own `Package.swift`, dependency pins, versioning). The **target (module)** is cheap and already enforces a hard boundary: a module can only see what it explicitly depends on. So we get strong boundaries from *modules* and pay package overhead only where it buys something concrete.

**A capability gets its own package only when at least one is true:**
1. It pulls a **heavy or risky third-party/system dependency** we don't want every other module (and every `swift test`) to compile against.
2. It needs an **independent validation harness** (CLI or manual test-app) that should sit beside it without dragging in the app.
3. It is a genuinely **reusable, self-contained engine** with zero knowledge of our app/data layers.

**Everything else lives as a target inside the one shared app package** (`BiscottiKit`), because app code refactors across boundaries constantly and module targets already keep it honest.

This directly answers the overview's open question ("small package vs. components of a package — you advise"): **components of a package by default; separate packages only for the three reasons above.** The judgment calls this produces are listed at the end for your review.

> **Project ≠ Package.** A *Project* (a future `/spec` build effort) can deepen a component that lives as a *module*. "Audio recording deserves its own project" does not require "audio recording is its own package." The two are decided independently.

---

## Workspace Layout

```
/                                  (repo root)
├── Packages/
│   ├── BiscottiKit/                  # the app package: most modules live here as targets
│   │   └── Sources/<Module>/ ...  # DataStore, Permissions, Calendar, Recording, … UI modules
│   ├── AudioCapture/              # own package (reason 2 + 3)
│   ├── Transcription/             # own package (reason 1: argmax-oss-swift; +2, +3)
│   └── Intelligence/   [P2]       # own package (reason 1: llama.cpp)
├── App/                           # the Xcode project — thin glue only
│   ├── Biscotti (app target)         # composition root + Apple-platform glue
│   └── BiscottiTranscriber (.xpc)    # XPC service target; links Transcription
└── (CI, lint, format config — added by the later Scaffolding project, not here)
```

Packages are consumed by the app via local SPM path references. The app project is the only thing that needs `xcodebuild`; `Packages/*` all build and test under `swift`.

---

## Layers

Dependencies flow strictly **downward** (a clean DAG; no cycles):

```
L4  App glue        Biscotti.app  ·  BiscottiTranscriber.xpc
L3b Window shell    AppShellUI  (window + sidebar + navigation; hosts the screens)
L3a Screens         HomeUI · RecordingUI · MeetingDetailUI · MeetingListUI · SearchUI
                    MenuBarUI · OnboardingUI · SettingsUI            (+ DesignSystem)
L2  Coordination    AppCore  (the headless "background app" engine)
L1  Services        Recording · MeetingDetection · TranscriptionService · Calendar · Notifications · Vocabulary
L0  Foundation      DataStore · Permissions · RemoteConfig · DesignSystem
        engines     AudioCapture(pkg) · Transcription(pkg) · Intelligence(pkg,P2)
```

---

## Component Cards

Each card is intentionally shallow. `Must provide` lists **outcomes**, never interfaces.

### Engine packages

#### 1. AudioCapture  ·  *own package*  ·  [V1]
- **Home:** own package (`Packages/AudioCapture`).
- **Owns:** the low-level systems engine for capturing and monitoring macOS audio. No app/data knowledge.
- **Must provide:** **(a) capture** — record mic + **global** system audio as two independent, time-aligned streams, written crash-safely to disk as **ADTS AAC** (`.aac` via `ExtAudioFile` + `kAudioFileAAC_ADTSType`, AAC-LC mono 24 kHz 64 kbps — self-syncing, crash-safe with no finalization; no CAF, no PCM scratch, no encode-on-stop, per phase9 finding #5); **survive audio route changes (file-preserving)** (a meeting starting *is* a route change — non-negotiable for a meeting recorder); **(b) monitoring** — observe **per-process** audio activity (which app is producing/consuming audio) as an event stream for meeting detection. Note: capture is global; per-process is monitoring-only (per Phase 9 validation, per-process capture was dropped).
- **Out of scope:** the data store, meeting semantics, the watchlist matching, UI, permission prompts (it reports capture failure; it doesn't own TCC), stream **merging**/mixdown (that's Transcription), **choosing storage locations** (it writes to caller-provided paths).
- **Depends on:** system frameworks only (Core Audio, AVFoundation). No internal deps.
- **Tested by:** unit tests for format/encoder/file logic; **manual hardware test-app** harness (successor to `AudioLab`) for live capture — lives beside the package.
- **Deep-dive risk:** **medium-high.** Research de-risked the approach; implementation still owns crash-safety, route-change survival, two-stream start-alignment, zero-buffer detection, and CPU/memory discipline. *Contingency:* Microsoft Teams may yield silent taps — global capture likely resolves it; ScreenCaptureKit is the documented fallback.
- **From:** `experiments/AudioLab`.

#### 2. Transcription  ·  *own package*  ·  [V1]
- **Home:** own package (`Packages/Transcription`).
- **Owns:** turning recorded audio into a rich diarized transcript, on-device, isolated from the host app.
- **Must provide:** produce a diarized transcript from a **set of labeled audio files** (mic + system), given as paths — it **owns the audio merging/muxing** and uses mic-vs-system provenance as a speaker-ID signal (merge for the SDK in V1; mic-based "me" identification later — the smarts live here, not upstream); manage models (download, cache, delete, disk-space check) with rich status (needs-download, downloading+progress, compiling, loading, running, errors); the in-process **client** to the isolated worker; memory/model load-unload lifecycle; custom-vocabulary biasing input; **sanitize output** for known SDK quirks (e.g. clamp/drop hallucinated segments past audio length, per validation); re-transcribe an existing recording.
- **Out of scope:** the data store (returns result values; persistence is `TranscriptionService`'s job), vocab *assembly* (receives a finished list), the XPC service bundle/entry point (that glue lives in the app project and links this package).
- **Depends on:** `argmax-oss-swift` (WhisperKit + SpeakerKit; MIT, vendors HuggingFace Hub Apache-2.0, SpeakerKit community model CC-BY-4.0 — app must carry attribution). No internal deps.
- **Tested by:** unit/integration tests on output shape against a bundled sample clip; **CLI harness** (successor to `argmaxkit-cli`); the isolation path exercised via the harness.
- **Deep-dive risk:** **high.** XPC + CoreML validation, model memory lifecycle, status surfacing, vocab workaround.
- **From:** `experiments/ArgMaxKit` (already an SPM package).

#### 3. Intelligence  ·  *own package*  ·  [P2]
- **Home:** own package (`Packages/Intelligence`).
- **Owns:** LLM-powered enhancements over transcripts.
- **Must provide:** summaries, action-item extraction, speaker-name inference, custom-vocab extraction from invites; a pluggable provider abstraction with a **local** (llama.cpp / Gemma) and an **external** (OpenAI-compatible base URL + key) implementation.
- **Out of scope:** the data store, transcription itself, UI.
- **Depends on:** llama.cpp Swift wrapper (local provider); consumes transcript values produced upstream. No internal deps.
- **Tested by:** unit tests with stubbed providers; integration test against a small local model.
- **Deep-dive risk:** **high**, but deferred (P2).
- **From:** none (new).

### Foundation modules (in `BiscottiKit`)

#### 4. DataStore  ·  *module in BiscottiKit*  ·  [V1]
- **Owns:** the SwiftData model and all persistence. The single owner of persistent types (Meeting/Event, versioned Transcript records, audio-file references, calendar-snapshot sub-item, notes, settings).
- **Must provide:** the schema + container/config; CRUD + queries/utilities; event↔recording association **and correction**; multiple transcript versions per meeting; **search** across meetings (simple SwiftData term matching for V1); the snapshot sub-item kept clearable in one operation. **[P2]** CloudKit/iCloud sync toggled via SwiftData's option.
- **Out of scope:** EventKit/audio/transcription specifics (it stores their results), UI, networking.
- **Depends on:** nothing internal (foundation). SwiftData.
- **Tested by:** unit tests against an in-memory container.
- **Deep-dive risk:** **medium** (schema design, versioned transcripts, migration, sync).
- **From:** informed by the `EventKitLab` data-availability report.

#### 5. Permissions  ·  *module in BiscottiKit*  ·  [V1]
- **Owns:** a unified view of every system permission the app needs.
- **Must provide:** status/request/denial-recovery for microphone, system-audio, and calendar; the silence-detection pre-check for system audio (per research; no private TCC API); a consistent "granted / denied / needs-action" surface for UI to drive onboarding and inline fixes.
- **Out of scope:** the prompts' UI (that's OnboardingUI), the capture/calendar logic itself.
- **Depends on:** nothing internal. System TCC APIs.
- **Tested by:** unit tests around the status state machine (system calls behind a seam); real prompts validated manually.
- **Deep-dive risk:** **low-medium.**
- **From:** `research/permissions`.

#### 6. RemoteConfig  ·  *module in BiscottiKit*  ·  [V1]
- **Owns:** the server-delivered config and pattern matching it powers.
- **Must provide:** fetch + cache the remote JSON (bundle-ID → app name; URL regexes → meeting platforms) with OTA refresh and a bundled fallback; matching API ("is this bundle ID a meeting app", "does this URL/text contain a conference link").
- **Out of scope:** audio/calendar/detection logic (it answers questions; others ask).
- **Depends on:** nothing internal. URLSession.
- **Tested by:** unit tests with fixture JSON.
- **Deep-dive risk:** **low.**
- **From:** `research/audio/meeting_app_bundle_ids.md` (seed data).

#### 7. DesignSystem  ·  *module in BiscottiKit*  ·  [V1]
- **Owns:** shared SwiftUI styling and reusable view primitives — the "tight, Apple-native" look.
- **Must provide:** shared components, colors/typography/spacing, common controls used across all UI modules.
- **Out of scope:** any feature/screen logic.
- **Depends on:** nothing internal. SwiftUI.
- **Tested by:** previews; light snapshot tests if useful.
- **Deep-dive risk:** **low.**
- **From:** none (new).

### Service modules (in `BiscottiKit`)

#### 8. Recording  ·  *module in BiscottiKit*  ·  [V1]
- **Owns:** the app-level recording lifecycle on top of the AudioCapture engine.
- **Must provide:** start/stop a recording session; **own storage locations** (decide the cache/file paths and tell AudioCapture where to write); create the Meeting/recording record on start and link the file paths as streaming begins; bind captured files into the data store; **recover orphaned/partial recordings on launch** and link them back to the data model (crash safety — never lose a meeting); manage the cache directory, conversion handoff, and cleanup; expose live recording state (elapsed, levels) for UI; honor permission state.
- **Out of scope:** low-level capture/encoding (AudioCapture), audio **merging**/diarization/STT (Transcription), meeting detection.
- **Depends on:** AudioCapture (pkg), DataStore, Permissions.
- **Tested by:** unit tests with a stubbed capture engine + in-memory store.
- **Deep-dive risk:** **medium.**
- **From:** `experiments/AudioLab` (recording path).

#### 9. MeetingDetection  ·  *module in BiscottiKit*  ·  [V1]
- **Owns:** deciding when a meeting starts/stops from system audio activity.
- **Must provide:** observe AudioCapture's per-process activity, match against the RemoteConfig watchlist, and emit "meeting started / stopped (app X)" events (for the ad-hoc-recording prompt and auto-stop).
- **Out of scope:** raw audio monitoring (AudioCapture), notification UX (Notifications/AppCore), recording.
- **Depends on:** AudioCapture (pkg), RemoteConfig.
- **Tested by:** unit tests feeding synthetic activity streams.
- **Deep-dive risk:** **medium.**
- **From:** `experiments/AudioLab` (streams path).

#### 10. TranscriptionService  ·  *module in BiscottiKit*  ·  [V1]
- **Owns:** the app-facing orchestration of the Transcription engine.
- **Must provide:** queue/run transcription jobs via the engine's isolated client (handing it the recording's audio file **paths** — the engine owns merging); assemble the effective vocabulary (from Vocabulary) for a job; surface model/job status to UI; persist results into DataStore as a new transcript version; trigger re-transcription on demand.
- **Out of scope:** the ML itself and model lifecycle (Transcription pkg), vocab source-of-truth (Vocabulary), UI.
- **Depends on:** Transcription (pkg), DataStore, Vocabulary, Permissions.
- **Tested by:** unit tests with a stubbed engine client + in-memory store.
- **Deep-dive risk:** **medium.**
- **From:** `experiments/ArgMaxKit` (integration side).

#### 11. Calendar  ·  *module in BiscottiKit*  ·  [V1]
- **Owns:** EventKit access and snapshotting events into our world.
- **Must provide:** request/enumerate calendars with include/exclude filtering; fetch events from selected calendars; snapshot the useful fields into the data model (surviving link breakage); conference-link detection via RemoteConfig; surface upcoming events for UI. **[P2]** optional Contacts enrichment.
- **Out of scope:** persistence schema ownership (DataStore), UI, recording.
- **Depends on:** DataStore, RemoteConfig. EventKit.
- **Tested by:** unit tests over snapshot mapping + filtering (EventKit behind a seam).
- **Deep-dive risk:** **low-medium** (research + `EventKitLab` already proved the path).
- **From:** `experiments/EventKitLab`.

#### 12. Notifications  ·  *module in BiscottiKit*  ·  [V1]
- **Owns:** user-facing notifications and their actions.
- **Must provide:** meeting-start notification (with join/record actions), ad-hoc-meeting-detected prompt, stop-recording countdown; deliver action callbacks for AppCore to act on.
- **Out of scope:** deciding *when* meetings start (MeetingDetection), performing recording (Recording) — it presents and reports intent.
- **Depends on:** DataStore. UserNotifications.
- **Tested by:** unit tests around content/scheduling (notification center behind a seam).
- **Deep-dive risk:** **low-medium.**
- **From:** none (new).

#### 13. Vocabulary  ·  *module in BiscottiKit*  ·  [V1]
- **Owns:** custom-vocabulary source-of-truth and merge logic.
- **Must provide:** store/edit the app-wide vocab list (in settings); merge it with per-meeting terms (participant/company names) into an effective list for a transcription job. **[P3]** per-recording manual additions.
- **Out of scope:** how the list biases the model (Transcription), settings UI.
- **Depends on:** DataStore.
- **Tested by:** unit tests over merge logic.
- **Deep-dive risk:** **low.**
- **From:** none (new).

### Coordination module (in `BiscottiKit`)

#### 14. AppCore  ·  *module in BiscottiKit*  ·  [V1]
- **Owns:** the headless "background app" engine — the flows that run with no window open.
- **Must provide:** wire detection → notification → recording → transcription into coherent flows ("meeting app started → prompt → record → on stop, queue transcription"); own app-wide run state the UIs observe; drive auto-stop and the recording/upcoming/recent data the menu bar shows; remain operational with no window. **[P2]** dispatch global-shortcut actions; **[P2]** invoke Intelligence features.
- **Out of scope:** rendering (UI modules), low-level capabilities (delegates to services), Apple-lifecycle glue (app target).
- **Depends on:** Recording, MeetingDetection, TranscriptionService, Calendar, Notifications, DataStore. **[P2]** Intelligence.
- **Tested by:** unit tests with stubbed services — the core of the app is validated headlessly, no UI.
- **Deep-dive risk:** **medium** (orchestration is where edge cases live).
- **From:** none (new).

### Presentation modules (in `BiscottiKit`)

Each screen is its **own module** (cheap target) so screens come online independently across Projects, view-models unit-test in isolation, and the window shell composes them. They share `DesignSystem` and read app state via `AppCore` / `DataStore`.

#### 15. AppShellUI  ·  *module in BiscottiKit*  ·  [V1]
- **Owns:** the main window container — sidebar, navigation/routing, and which screen is shown.
- **Must provide:** the sidebar (home, recording indicator, upcoming, past); routing between the screen modules; the search-takeover entry/exit; window chrome. Hosts the screens; owns no screen content itself.
- **Out of scope:** any screen's own content/logic (those are the screen modules).
- **Depends on:** the window screen modules (Home/Recording/MeetingDetail/MeetingList/Search), AppCore, DesignSystem.
- **Tested by:** routing/navigation view-model tests; views via previews.
- **Deep-dive risk:** **low-medium.** **From:** none.

#### 16. HomeUI  ·  *module in BiscottiKit*  ·  [V1]
- **Owns:** the home/welcome screen.
- **Must provide:** welcome content, a prominent start-recording action, and a preview of upcoming meetings.
- **Depends on:** AppCore, DataStore, Calendar (upcoming preview), DesignSystem.
- **Tested by:** view-model unit tests; previews.
- **Deep-dive risk:** **low.** **From:** none.

#### 17. RecordingUI  ·  *module in BiscottiKit*  ·  [V1]
- **Owns:** the active-recording screen.
- **Must provide:** live recording state (elapsed, levels), stop control, and the current meeting context while recording.
- **Depends on:** AppCore, Recording, DesignSystem.
- **Tested by:** view-model unit tests; previews.
- **Deep-dive risk:** **low-medium.** **From:** none.

#### 18. MeetingDetailUI  ·  *module in BiscottiKit*  ·  [V1]
- **Owns:** the single-meeting screen.
- **Must provide:** render a meeting's diarized transcript, metadata (title/participants/times), notes, and calendar context; audio playback; transcript-version switching + a re-transcribe action; event-association correction entry point.
- **Depends on:** DataStore, TranscriptionService (re-transcribe/status), AppCore, DesignSystem.
- **Tested by:** view-model unit tests; previews.
- **Deep-dive risk:** **medium** (richest screen). **From:** none.

#### 19. MeetingListUI  ·  *module in BiscottiKit*  ·  [V1]
- **Owns:** the past/upcoming meeting lists.
- **Must provide:** scrollable past-meetings list and upcoming list, with navigation into a meeting.
- **Depends on:** DataStore, AppCore, DesignSystem.
- **Tested by:** view-model unit tests; previews.
- **Deep-dive risk:** **low.** **From:** none.

#### 20. SearchUI  ·  *module in BiscottiKit*  ·  [V1]
- **Owns:** the search experience (the takeover view + results).
- **Must provide:** live-filtering results as the user types, across title/people/transcripts; navigation into a result; back-to-previous-view.
- **Depends on:** DataStore (search queries), AppCore, DesignSystem.
- **Tested by:** view-model unit tests; previews.
- **Deep-dive risk:** **low-medium.** **From:** none.

#### 21. MenuBarUI  ·  *module in BiscottiKit*  ·  [V1]
- **Owns:** the tray/menu-bar experience + its view models.
- **Must provide:** icon states (idle / next-meeting text with truncation / recording); body (recording status + start/stop, upcoming, recent w/ links, open-app, quit).
- **Depends on:** AppCore, DataStore, DesignSystem.
- **Tested by:** view-model unit tests; views via previews.
- **Deep-dive risk:** **low-medium.** **From:** none.

#### 22. OnboardingUI  ·  *module in BiscottiKit*  ·  [V1]
- **Owns:** the setup wizard.
- **Must provide:** permission steps (mic, system-audio, calendar) with denial-fix guidance; calendar selection; model-download step with progress + disk check; optional demo.
- **Depends on:** Permissions, Calendar, TranscriptionService (model status), DesignSystem, AppCore.
- **Tested by:** view-model unit tests; flow validated manually.
- **Deep-dive risk:** **medium.** **From:** none.

#### 23. SettingsUI  ·  *module in BiscottiKit*  ·  [V1]
- **Owns:** settings screens.
- **Must provide:** calendar include/exclude; custom-vocab editing; launch-on-startup toggle. **[P3]** audio file-usage view + deletion.
- **Depends on:** Calendar, Vocabulary, DataStore, DesignSystem.
- **Tested by:** view-model unit tests.
- **Deep-dive risk:** **low.** **From:** none.

### App-glue targets (in the Xcode project — *not* packages)

#### 24. Biscotti (app target)  ·  *app-project glue*  ·  [V1]
- **Owns:** the composition root and the irreducible Apple-platform glue.
- **Must provide:** instantiate the DataStore container and wire AppCore + the two scenes (`AppShellUI` window + `MenuBarExtra`/`MenuBarUI`) incl. accessory (background) activation; entitlements, Info.plist usage strings, asset catalog; non-sandboxed config; third-party license attribution (e.g. argmax-oss-swift); launch-on-startup registration (`SMAppService`); App Intents; embed the XPC service. *(Developer ID / hardened runtime / notarization are configured by the separate Distribution project.)* **[P2]** global keyboard-shortcut registration.
- **Out of scope:** business logic and screen content (all in packages).
- **Depends on:** BiscottiKit (AppShellUI, MenuBarUI, AppCore), Transcription (via the XPC service), DataStore.
- **Tested by:** **app/UI test tier only** (non-gating CI); thin enough that little needs it.
- **Deep-dive risk:** **low logic / medium integration.** **From:** none.

#### 25. BiscottiTranscriber (XPC service)  ·  *app-project glue*  ·  [V1]
- **Owns:** the crash-isolated host process for transcription.
- **Must provide:** the `.xpc` service bundle, entry point, plist, and entitlements; link the Transcription package's worker and expose it across the XPC boundary; auto-relaunch by launchd.
- **Out of scope:** the ML logic (lives in the Transcription package).
- **Depends on:** Transcription (pkg).
- **Tested by:** exercised via the Transcription harness + app integration.
- **Deep-dive risk:** **medium** (validated together with Transcription). **From:** `research/argmax` (isolation).

---

## Dependency Graph

```mermaid
graph TD
  subgraph App glue (Xcode project)
    APP[Biscotti.app]
    XPC[BiscottiTranscriber.xpc]
  end
  subgraph BiscottiKit (one package, many targets)
    SHELL[AppShellUI]
    HOME[HomeUI]; RECUI[RecordingUI]; DETAIL[MeetingDetailUI]; LIST[MeetingListUI]; SRCH[SearchUI]
    MENU[MenuBarUI]; ONB[OnboardingUI]; SET[SettingsUI]; DS[DesignSystem]
    CORE[AppCore]
    REC[Recording]; DET[MeetingDetection]; TS[TranscriptionService]; CAL[Calendar]; NOTIF[Notifications]; VOC[Vocabulary]
    STORE[DataStore]; PERM[Permissions]; RC[RemoteConfig]
  end
  AUD[(AudioCapture pkg)]; TRX[(Transcription pkg)]; INT[(Intelligence pkg P2)]

  APP --> SHELL & MENU & CORE & STORE
  XPC --> TRX
  SHELL --> HOME & RECUI & DETAIL & LIST & SRCH & CORE & DS
  HOME --> CORE & STORE & CAL & DS
  RECUI --> CORE & REC & DS
  DETAIL --> STORE & TS & CORE & DS
  LIST --> STORE & CORE & DS
  SRCH --> STORE & CORE & DS
  MENU & ONB & SET --> CORE & DS
  ONB --> PERM & CAL & TS
  SET --> CAL & VOC & STORE
  MENU --> STORE
  CORE --> REC & DET & TS & CAL & NOTIF & STORE
  CORE -.P2.-> INT
  REC --> AUD & STORE & PERM
  DET --> AUD & RC
  TS --> TRX & STORE & VOC & PERM
  CAL --> STORE & RC
  NOTIF --> STORE
  VOC --> STORE
```

No cycles. Leaves: `DataStore`, `Permissions`, `RemoteConfig`, `DesignSystem`, and the three engine packages.

---

## Thin-App Composition

What stays in the app target (and the XPC target), and why it can't be a package:

- **Composition root** — the one place that knows about all modules to wire them; by definition not a reusable library.
- **SwiftUI `App`/scene declaration**, `MenuBarExtra`, accessory/background activation policy — app-process entry points.
- **Entitlements, Info.plist usage strings, asset catalog, App Intents, `SMAppService` launch-at-login, the embedded `.xpc` bundle** — Apple-platform glue that requires the Xcode project graph + signing.

Everything testable — view models, navigation, services, orchestration, even most views — lives in packages and runs under `swift test`. The app target is the only thing requiring `xcodebuild`, and it carries no business logic. This is the structural payoff: agents work in `Packages/*` 99% of the time; the app/UI test tier is separate and non-gating.

---

## Cross-Cutting Conventions

Not components — conventions every component follows, recorded so they don't fall through the cracks:

- **Logging/diagnostics:** each component uses `os.Logger` with its own subsystem/category. No separate logging package; diagnostics go to unified logging, never stdout. (For a "rock-solid recorder," observability of capture/route/zero-buffer events matters.)
- **Error surfacing:** errors propagate to the user-facing surface (UI/notification); no silent failures, especially in the capture and transcription paths.
- **No business logic in glue:** anything testable belongs in a package (see Thin-App Composition).

---

## P2 / P3 Placement (where future work slots in)

| Future capability | Home | Notes |
|---|---|---|
| LLM summaries / action items / speaker-naming / vocab-extraction | **Intelligence** (new pkg) + AppCore + MeetingDetailUI | Provider abstraction (local llama.cpp + external). |
| iCloud/CloudKit sync | **DataStore** (config) | SwiftData sync option; not a new package. |
| Global keyboard shortcut | **Biscotti app** (glue) + AppCore (dispatch) | Mostly Apple glue. |
| Per-recording manual vocab | **Vocabulary** + MeetingDetailUI/SettingsUI | Extends existing modules. |
| Audio file-usage view + deletion | **SettingsUI** + DataStore/Recording | File accounting. |
| Contacts enrichment | **Calendar** | Measured in research; deferred. |
| Opus encoding (smaller files) | **AudioCapture** | Revisit at macOS 16+ (`kAudioFormatOpus`); ~½ size. |
| Auto speaker identification (who is who, incl. "me") | **Transcription** + DataStore (identity/voiceprint store) + MeetingDetailUI (confirm/correct) | Two signal methods: mic/system **stream-timing** ("me") + cross-recording **centroid voiceprints** (SDK does **not** expose centroid embeddings in v1.0.0 — see `research/argmax` §6 erratum; reserved for a future SDK version). Complements LLM name-inference. P2. |
| App auto-update | **Distribution project** (TBD) | May never self-distribute (could be App Store); manual update is fine for V1. Decide if/when we ship Developer-ID. |

Every post-V1 capability has a home in the shape above — none forces a re-topology.

---

## Granularity Decisions (resolved)

The package-vs-module calls, with their resolutions:

1. **AudioCapture as its own package** (vs. a BiscottiKit module). **DECIDED: own package** — for engine isolation + its hardware test-app harness. (Weakest of the three splits since it has no heavy third-party dep, but the boundary is worth it.)
2. **Recording / MeetingDetection split from AudioCapture.** **Kept** — the low-level engine (package) stays separate from the app-level services (modules) so the engine remains app/data-free and reusable.
3. **DataStore as one module** (vs. splitting pure model types from the store/queries). **DECIDED: one module** — idiomatic for SwiftData `@Model`; the boundary-crossing data already uses plain `Sendable` DTOs from the engine packages, so the usual reason to split doesn't apply here. *Escape hatch:* if the DataStore build project hits real view-model-testing or strict-concurrency friction with live `@Model` objects, it may extract a pure `Models` leaf + mappers then — an internal, additive refactor (new leaf below DataStore; type-only dependents repoint), not a re-topology.
4. **One UI module per screen** (Home, Recording, MeetingDetail, MeetingList, Search, plus MenuBar/Onboarding/Settings), with `AppShellUI` composing the window screens. **Chosen over a single `AppWindowUI`** so screens come online in different Projects (MVP ships Recording + MeetingDetail + basic List + Shell; Home/Search arrive later), each view-model unit-tests in isolation, and no screen becomes a god-module. Targets are cheap; this is the granularity sweet spot for UI. Collapse only if a screen is too thin to warrant its own module.
5. **Intelligence as its own package** — **kept** (quarantines llama.cpp); P2, easy to revisit.
