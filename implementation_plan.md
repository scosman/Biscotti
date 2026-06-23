---
status: complete
---

# Implementation Plan: Biscotti Build Roadmap

A dependency-ordered **roadmap of Projects**. Each entry is a future `/spec new project` with its own specing and phases — **not** a phase implemented from here. There is no `/spec implement` step for `library_design`; this plan spawns the next projects.

**How to read an entry.** Each lists *what's in the Project* — the components/parts and capabilities it covers, what it delivers, its dependencies, archetype, and risk. It does **not** break the Project into phases; that's decided when the Project is itself spec'd. Components are grown **incrementally across Projects** (a component may appear in several).

**Two archetypes** (see [functional spec](specs/projects/library_design/functional_spec.md)):
- **Foundation/library** — one complex component built deep; validated by tests + a manual harness; **does not ship a runnable app**. These are front-loaded to retire risk.
- **Feature/integration** — delivers a **self-standing, runnable app increment** by wiring built components + UI. From the MVP onward, *every* Project leaves a working app.

Component homes and boundaries are defined in [`architecture.md`](architecture.md).

---

## Stage A — Foundations (no runnable app yet)

> **Delivery status (Stage A build).** Projects 0–3 and the Stage-A Manual Test App are **built and autonomously green** (`lint` + `test` + `build_app`), delivered via the `stage_a_foundations` spec project: **Project 1 — Transcription** (`Packages/Transcription`, incl. the shared `XPCServices/BiscottiTranscriber.xpc` glue), **Project 2 — Audio Capture** (`Packages/AudioCapture`, ADTS-AAC capture + per-process monitoring), **Project 3 — Data Store** (`DataStore` module in `BiscottiKit`), plus **`ManualTestKit` + `ManualTestApp`** (the hardware test harness) and the `manual-tests-check` CI gate. **Hardware/human sign-off is still pending:** the Manual Test App's *Phase 4.5* — running every scripted test on real Apple-silicon hardware — has not been done yet, so the `manual-tests-check` gate is intentionally RED until those results are recorded. The library-level **AI test set** for Transcription (Project 5 below) and transcript-text **search** (Project 7) remain as their own future projects.

### Project 0 — Scaffolding & Tooling
- **Archetype:** foundation (infrastructure).
- **Delivers:** the repo skeleton that everything else is built in — buildable empty `BiscottiKit` package + thin `App` Xcode project that launches, with green CI.
- **In scope:** the `Packages/` + `App/` workspace layout from `architecture.md`; `BiscottiKit` package skeleton; thin app-target shell; **dev signing** — lock in the **stable production bundle ID** (TCC grants depend on it) + ad-hoc/local signing for dev & CI builds (real Developer-ID notarization is the separate Distribution project); entitlements; CI (GitHub Actions) running the **gating package-test tier** and the **non-gating app/UI tier**; lint + format (fix & check) + pre-commit hook; agent/build integration (XcodeBuildMCP for the rare `xcodebuild` paths); repo `CLAUDE.md` with the check commands.
- **Depends on:** nothing.
- **Risk:** **medium** — xcodebuild/CI reliability is the historically painful part; this Project exists largely to nail it once.

### Project 1 — Transcription Library
- **Archetype:** foundation/library.
- **Delivers:** the validated on-device STT+diarization library, running crash-isolated, with a CLI harness. Productionizes `experiments/ArgMaxKit`.
- **In scope:** the `Transcription` package (diarized transcript from a **set of labeled audio files** (mic+system) given as paths — owns audio merging/muxing + the mic-vs-system speaker-ID signal; rich result, model download/cache/delete + disk check, rich status, memory/load-unload lifecycle, custom-vocab biasing input, output sanitization for known SDK quirks, re-transcribe); the `BiscottiTranscriber.xpc` glue target and **end-to-end XPC + CoreML isolation validation** (the last residual unknown from research); the CLI harness.
- **Depends on:** Project 0.
- **Risk:** **high** — pulled earliest to retire the XPC/CoreML risk first.

### Project 2 — Audio Capture Library
- **Archetype:** foundation/library.
- **Delivers:** the validated low-level audio engine + a hardware test-app harness. Productionizes `experiments/AudioLab`.
- **In scope:** the `AudioCapture` package (mic + **global** system-audio two-stream capture, crash-safe write, long-term-storage repackage/conversion, **route-change survival**, per-process audio **monitoring** for detection, two-stream start-alignment, zero-buffer detection; ScreenCaptureKit-fallback contingency for Teams); the manual hardware harness beside it.
- **Depends on:** Project 0.
- **Risk:** **medium-high.**

### Project 3 — Data Store
- **Archetype:** foundation/library.
- **Delivers:** the validated SwiftData persistence layer (tested against an in-memory container).
- **In scope:** the `DataStore` module (schema: Meeting/Event, versioned Transcript records, audio-file refs, calendar-snapshot sub-item, notes, settings; container/config; queries/utilities; event↔recording association **and correction**; simple V1 search; sync-*ready* config — sync itself is Project 12).
- **Depends on:** Project 0.
- **Risk:** **medium.**

> **Projects 1–3 are mutually independent** (each only needs Scaffolding) and can run in parallel. Recommended risk-priority if serialized: **Transcription first** (biggest residual unknown), then Audio Capture, then Data Store.

### Project 4 - Manual Test App

See specs/project/manual_test_app

### Project 5 - AI test set

Create a new test set for "AI tests". These can be run via CLI just fine, but require downloading gigabytes of models, and long expensive processing (audio transcibe, speaker ID, LLM tests). We want to isolate these (not required every small commit), but still automated tests, not relying on manual.

 - Create the test set/tag, excluded by default when running `make test`
 - Add new make command to run these.
 - Add them for Project 1, which should be testable this way. You'll need a reference audio file with ground truth transcription (ask user for this). Should be slightly flexbile in tests: speaker count correct, levechtien distance of full transcript small but not exact.

---

## Stage B — First runnable app

### Project 4 — MVP: Record → Transcribe App
- **Archetype:** feature/integration. **First runnable, shippable app.**
- **Delivers:** start recording a meeting, stop, get a diarized transcript stored and viewable — **no calendar, no auto-detection, no notifications, no home/search.**
- **In scope (first slices of these components):** thin `Biscotti` app target (composition root); `AppShellUI` (basic window + sidebar + routing); `RecordingUI` (active-recording screen); `MeetingDetailUI` (basic — transcript + metadata; re-transcribe); `MeetingListUI` (basic past-meetings list to get back into a meeting); minimal `MenuBarUI` (start/stop, recent); `Recording` module (session lifecycle over AudioCapture, owns storage paths/locations, create+link record on start, persist into DataStore, recover orphaned recordings on launch); `TranscriptionService` module (hand audio paths to the engine → persist transcript version → status → re-transcribe); `Permissions` module (mic + system-audio, silence pre-check, denial recovery); minimal `DesignSystem`.
- **Depends on:** Projects 1, 2, 3 (+ 0).
- **Risk:** **medium** — first real integration: permissions, capture→file→transcript→store→UI.

---

## Stage C — V1 feature layering (each ships a working app)

### Project 5 — Calendar Integration
- **Archetype:** feature/integration.
- **Delivers:** app shows upcoming meetings, enriches recordings with calendar context, and lets the user choose which calendars count.
- **In scope:** `Calendar` module (EventKit access, calendar include/exclude filtering, event snapshot into DataStore, conference-link detection); `RemoteConfig` module (**first slice:** load/cache the server JSON — conference-URL regexes + bundle IDs, with bundled fallback); `Permissions` (+calendar); `SettingsUI` (**first slice:** calendar selection); `MenuBarUI`/`MeetingListUI` additions (show upcoming); `MeetingDetailUI` additions (calendar context on a meeting).
- **Depends on:** Project 4.
- **Risk:** **low-medium** (research + `EventKitLab` already proved the path).

### Project 6 — Meeting Detection, Background Operation & Notifications
- **Archetype:** feature/integration.
- **Delivers:** the app runs in the background without a window, detects meetings starting (calendar-driven and ad-hoc audio), notifies with record actions, and offers auto-stop.
- **In scope:** `MeetingDetection` module (per-process audio activity → meeting start/stop via watchlist); `RemoteConfig` additions (bundle-ID meeting-app watchlist); `Notifications` module (meeting-start, ad-hoc-detected, stop-recording countdown + action callbacks); `AppCore` (**first real slice:** wire detection → notification → record → transcribe; background run state; menu-bar data); app-target glue (accessory/background activation, launch-on-startup).
- **Depends on:** Projects 4, 5 (calendar-driven starts), Project 2 (monitoring).
- **Risk:** **medium** — orchestration and background lifecycle.

### Project 7 — Home, Library & Search
- **Archetype:** feature/integration.
- **Delivers:** the full browsing experience — a home screen, a rich meeting library, and search across all meetings.
- **In scope:** `HomeUI` (welcome, start-recording, upcoming-meetings preview); `SearchUI` (live-filtering search across title/people/transcripts, takeover + back); `MeetingListUI` (**rich slice:** full past/upcoming lists, grouping); `MeetingDetailUI` (**rich slice:** audio playback, transcript-version switching, notes editing, association correction); `AppShellUI` (full sidebar + search entry); `DataStore` (search query support, if not already present).
- **Depends on:** Projects 4, 5 (Home's upcoming preview + meeting calendar context).
- **Risk:** **low-medium.**

### Project 8 — Onboarding, Settings & Custom Vocabulary
- **Archetype:** feature/integration.
- **Delivers:** a real first-run experience and the settings that make transcripts better.
- **In scope:** `OnboardingUI` (full wizard: permissions w/ denial-fix guidance, calendar selection, model download w/ progress + disk check, optional demo); `SettingsUI` (custom-vocab editing, launch-on-startup, consolidated calendar selection); `Vocabulary` module (app-wide list + per-meeting merge); `TranscriptionService` additions (consume the merged vocab).
- **Depends on:** Projects 4, 5, 1 (model status/download).
- **Risk:** **medium.**
- **Blocker (custom vocab only):** WhisperKit's `promptTokens` API silently blanks the entire transcript for certain term combinations. This affects both turbo and non-turbo models. Product-side custom-vocab work should not start until the SDK issue is resolved. Tracked upstream: [argmax-oss-swift#489](https://github.com/argmaxinc/argmax-oss-swift/issues/489), [argmax-oss-swift#428](https://github.com/argmaxinc/argmax-oss-swift/pull/428). The AI test for custom vocab is disabled pending this fix.

> End of Project 8 = **feature-complete V1**: onboarding → detect/record → diarized transcript (with custom vocab) → home/library/search, all on-device.

---

## Stage D — Post-V1 (P2/P3) & Release

### Project 9 — Distribution & Release  ·  [post-MVP]
- **Archetype:** release-enablement (separate from dev scaffolding).
- **Delivers:** a signed, notarized, distributable build — the real shipping pipeline.
- **In scope:** Developer ID signing, hardened runtime, notarization + stapling, release packaging; a CI release workflow; **[TBD]** an app **auto-update** mechanism (e.g. Sparkle) — *only if* we self-distribute (may instead be App Store, or manual updates for V1).
- **Depends on:** Project 4 (something to ship). Off the feature critical path — can run any time post-MVP, whenever we want to ship to real users.
- **Risk:** **medium.**

### Project 10 — Intelligence (LLM)  ·  [partially built]
- **Archetype:** library + feature.
- **Delivers:** LLM summaries, action items, speaker-name inference, and vocab extraction from invites.
- **Status:** The **`llm_features` spec project** built the core AI features ahead of this roadmap entry: **summarization** (streamed, editable, auto-run + manual generate/regenerate) and **speaker-name inference** (LLM-based + manual mapping sheet). These are implemented as the `Intelligence` module in `BiscottiKit` (not a separate package), wired into `AppCore` (auto-run after transcription), `MeetingDetailUI` (Summary tab, speaker names in transcript, mapping sheet), and `SettingsUI` (AI Enhancements section with toggles + model download). `DataStore` additions (summary, editedSummary, speakerAssignments, allPersonData) are also built.
- **Remaining scope:** provider abstraction (external OpenAI-compatible provider + API-key config in Settings), vocab extraction from invites.
- **Depends on:** Project 4 (transcripts), Project 3. **Note:** the `LocalLLM` runtime and `BiscottiLLM.xpc` service are already graduated and hardware-validated (via the `graduate_llm_package` spec project).
- **Risk:** **medium** (core features built; remaining work is the provider abstraction and vocab extraction).

### Project 11 — Auto-Speaker Identification  ·  [P2]
- **Archetype:** library + feature (deepens Transcription's speaker smarts).
- **Delivers:** automatically work out *who* each speaker is — pin "me" and recognize recurring people across meetings — without manual labeling. **Signal-based; distinct from and complementary to Project 10's LLM name-inference.**
- **In scope (the two methods):**
  - **Stream-timing correlation** (Transcription) — align mic-stream vs system-stream volume against transcript timestamps to identify "me" (mic) vs the other party/parties (system) within a recording.
  - **Cross-recording voiceprints** (Transcription) — use the SDK's speaker **centroid embeddings** (now exposed) to match speakers across recordings (recognize "me" and known people over time).
  - **Identity store** (DataStore) — persist per-recording embeddings + a known-speaker/voiceprint store; map diarization labels → identities.
  - **Confirm/correct UI** (MeetingDetailUI) — user confirms or fixes an identity, feeding the voiceprint store.
- **Depends on:** Project 1 (Transcription — owns the audio smarts + embeddings), Project 3 (DataStore), Project 4 (a corpus of recordings). Pairs with Project 10 (LLM naming).
- **Risk:** **high** (signal heuristics + embedding-distance thresholds).

### Project 12 — iCloud Sync  ·  [P2]
- **Archetype:** feature/integration.
- **Delivers:** meetings, transcripts, and audio synced across the user's devices.
- **In scope:** `DataStore` CloudKit sync config; audio-file sync; conflict handling; a settings toggle.
- **Depends on:** Project 3 (+ a meaningful data set, so realistically after Project 4).
- **Risk:** **medium-high.**

### Project 13 — Power-User & Storage Polish  ·  [P2/P3]
- **Archetype:** feature/integration (grab-bag of small, independent slices).
- **Delivers:** assorted enhancements, each a thin slice on the working app.
- **In scope:** **[P2]** global configurable start/stop keyboard shortcut (app glue + AppCore dispatch); **[P3]** audio file-usage view + deletion (SettingsUI + DataStore/Recording accounting); **[P3]** per-recording manual vocab additions (Vocabulary + MeetingDetailUI); search improvements (FTS) if warranted.
- **Depends on:** Project 4 (and the specific components each slice touches).
- **Risk:** **low-medium.** Likely split into several tiny Projects when the time comes.

### Project 14 — Custom Vocabularies  ·  blocked
 - Implement the planned custom vocabulary project. However it's blocked as the SDK fails whenever you add a custom vocabulary. Fix identified, waiting for ArgMax to merge.

---

## Critical Path & Parallelism

- **Critical path:** `0 Scaffolding → {1 Transcription | 2 Audio | 3 DataStore} → 4 MVP → 5 Calendar → 6 Detection/Notifications → 7 Home/Library/Search → 8 Onboarding/Settings`.
- **Parallelizable:** Projects 1, 2, 3 after Scaffolding (independent foundations). In Stage C, Project 7 (Home/Library/Search) is independent of Project 6 (Detection/Notifications) — both depend only on 4 and 5, so they can run in parallel. Project 9 (Distribution) is off the feature path and can run any time post-MVP. Within Stage D, Projects 10/11/12/13 are largely independent.
- **Risk front-loading:** the two highest-risk efforts (Transcription's XPC/CoreML isolation, Audio Capture's two-stream/crash-safety) are the first real work after Scaffolding — failures surface before any UI is built on top.
- **First usable app:** end of Project 4. **Feature-complete V1:** end of Project 8. **Shippable (signed/notarized):** Project 9, any time post-MVP.

## Summary

| # | Project | Archetype | Runnable app? | Depends on | Risk |
|---|---------|-----------|---------------|------------|------|
| 0 | Scaffolding & Tooling | foundation | no | — | medium |
| 1 | Transcription Library | foundation/library | no | 0 | high |
| 2 | Audio Capture Library | foundation/library | no | 0 | med-high |
| 3 | Data Store | foundation/library | no | 0 | medium |
| 4 | MVP: Record → Transcribe | feature/integration | **yes** | 1,2,3 | medium |
| 5 | Calendar Integration | feature/integration | yes | 4 | low-med |
| 6 | Detection / Background / Notifications | feature/integration | yes | 4,5 | medium |
| 7 | Home, Library & Search | feature/integration | yes | 4,5 | low-med |
| 8 | Onboarding / Settings / Vocab | feature/integration | yes | 4,5,1 | medium |
| 9 | Distribution & Release | release-enablement | ships | 4 | medium · post-MVP |
| 10 | Intelligence (LLM) | library+feature | yes | 4,3 | medium · partially built |
| 11 | Auto-Speaker Identification | library+feature | yes | 1,3,4 | high · P2 |
| 12 | iCloud Sync | feature/integration | yes | 3,4 | med-high · P2 |
| 13 | Power-User & Storage Polish | feature/integration | yes | 4 | low-med · P2/P3 |
