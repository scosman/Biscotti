---
status: complete
---

# Functional Spec: Research

This project is **research, not product**. Its output is knowledge (decision docs) and disposable reference apps (experiments) that de-risk the Biscotti app's hard technical bets. Success is measured by whether, at the end, we can design the core app with **no significant remaining technical unknowns**.

See [`specs/app_overview.md`](../../app_overview.md) for the product this research serves.

## Definition of Done

The project is done when:

1. Every research area below has a **decision doc** under `/specs/research/<area>/` that answers its key questions and records a clear recommendation (not just options).
2. Every experiment app/library builds, runs, and demonstrates its target capability on real hardware.
3. Every validation script has been run by the user and its results recorded back into the relevant research doc.
4. A short top-level `/specs/research/README.md` summarizes the recommendations and links the per-area docs.

## Baseline Assumptions

- **Target:** Apple Silicon only, macOS 15+. Newest APIs are fair game.
- **Language/UI:** Swift + SwiftUI. SwiftUI app-building and plain SwiftData usage are considered known and are **out of research scope**.
- **ArgMax:** use the **free** `argmax-oss-swift` SDK (not Pro).
- Experiments may be rough; their job is to prove a technique and generate reference code, not to be production-clean.

## Deliverable Conventions

- **Research docs:** `/specs/research/<area>/` (e.g. `/specs/research/audio/`). Markdown. Each ends with a **Recommendation** section and an **Open questions for the team** section (genuine choices to send to the ArgMax folks or revisit later).
- **Experiments:** `/experiments/<Name>/`, each an independent, self-contained app/package. Lighter test bar — test where it materially helps; these are throwaway/reference.
- **Validation:** each experiment ships a short `VALIDATION.md` (a numbered manual test script the user runs; agent writes it, human clicks and confirms).

---

## Research Areas

Four areas. Research is performed by sub-agents **during implementation**, not now. This spec defines *what each must answer and deliver*.

### R1 — Audio Capture & Recording

The audio API is itself an open question — **find the best API**, don't assume Core Audio. Candidates to evaluate include Core Audio process taps (`CATapDescription` / `AudioHardwareCreateProcessTap` + aggregate device, macOS 14.4+), ScreenCaptureKit audio, and any better option. Reference projects to mine: AudioCap (insidegui), AudioTee.

**Key questions:**
- What is the best macOS 15 API to capture **both** the user's mic and the **other participants' audio** (system/app output) during a meeting?
- Can we capture mic and meeting-output as **independent streams** (helps identify "me")? Can we also get a merged stream? Which should we record?
- Can we identify the **source app** of an audio stream (e.g. Zoom.app, Chrome.app)? Can we detect meetings **starting/stopping** by watching streams appear/disappear?
- What **audio format/compression** fits voice at small file size (e.g. ~48 kbps AAC-LC mono, or record native then convert for long-term storage)? Recommend concrete encoder settings.
- How do we **stream to disk safely** so an app crash leaves a usable partial recording (P2 but design for it)?
- What are the **failure modes** (e.g. zero-filled buffers on sample-rate renegotiation, level attenuation with multi-output devices) and their mitigations?
- What is the **CPU/memory/NPU** cost of the recording path? (Goal: rock-solid, lightweight recorder that never crashes.)

**Deliverable:** `/specs/research/audio/` doc with a recommended API, stream strategy (1 vs 2 streams), recommended format/encoder settings, crash-safe streaming approach, and known gotchas + mitigations.

### R2 — EventKit / Calendar

**Key questions:**
- How do we request and obtain calendar access on macOS 15 (full-access model, prompt UX)?
- How do we enumerate calendars so the user can **filter** which are included (e.g. exclude "Family")?
- What event fields are available — title, participants/attendees, organizer, description, times, conferencing/URL info — and in what shape?
- What's the right way to **copy** event data into our own model so we don't depend on the EventKit link persisting?

**Deliverable:** `/specs/research/eventkit/` doc, including a **data-availability report** (every useful field EventKit exposes) to inform the core app's `Meeting`/`Event` data model.

### R3 — ArgMax STT + Diarization (incl. ML Isolation & Lifecycle)

Wrap WhisperKit (STT) + SpeakerKit (diarization) from `argmax-oss-swift` into a simple library: roughly `processAudio(audioFile) -> transcriptObject`. This may graduate to a real shipped library, so it gets a **higher testing bar** than the other experiments. This area also owns **how to run the ML so a crash or memory spike can't take down the app** — isolation and lifecycle are part of the library's design, not a separate study.

**Key questions — SDK & models:**
- **Model confirmation (priority):** confirm **Parakeet V3** (STT) and **`nvidia/sortformer-v2-1`** (diarization) are available in ArgMax's model library, load successfully, and run on the **free** SDK. (The README may not list them; verify against the actual model library, not just docs.) If either truly isn't viable on free, identify the best free alternative and flag it.
- How are models **downloaded and stored** (HuggingFace cache, paths, size on disk, first-run download UX)?
- What does the **transcript output** contain (turns, speaker IDs, timestamps, confidences, word-level data)? Capture it **richly** so the Meeting model can store everything and render a subset.
- **Custom vocabulary:** what's supported, limits, how it's passed in?
- 1 vs 2 input streams: what does the SDK support — merged audio, or time-aligned separate streams to aid speaker ID?
- Does diarization label "Speaker A/B…" only (confirm), and is there any path to **speaker ID across files** (recognize "me" over time)?

**Key questions — isolation & lifecycle:**
- Isolation: XPC service vs subprocess vs background thread/actor — which keeps a crash off the main app and off the main thread? Recommend one.
- Where does the model work run so it never touches the main thread / blocks the UI?
- Memory lifecycle: can STT and diarization run **one at a time**, or must both be resident? Load/unload costs, peak memory, behavior under pressure, min memory / hardware floor.
- How does this compose with the `processAudio` API (e.g. the call runs in the isolated worker)?

**Deliverables:**
- `/specs/research/argmax/` doc answering the above (covering both SDK/models and the recommended isolation+lifecycle architecture), **plus** a drafted "**Questions for the ArgMax team**" list at a "we obviously read the code, these are good questions" level (including a "confirm this approach sounds good" summary).
- The `processAudio` library (see Experiment E3).

### R4 — Permissions Matrix

One consolidated doc covering **every** system permission the app will need.

**Key questions:**
- For each of: **microphone**, **system/meeting audio capture**, **screen recording** (only if the chosen audio API requires it), **calendar (full access)** — what triggers the prompt, which Info.plist usage-description keys / entitlements are required, and what the user-facing UX is.
- Sandboxing & **notarization** implications of the chosen audio API and entitlements.
- Ordering/strategy: when to request each, how to pre-check status (e.g. TCC probing) and handle denial/re-request gracefully.

**Deliverable:** `/specs/research/permissions/` doc — a table of permission → key/entitlement → prompt trigger → handling, plus sandbox/notarization notes. Cross-references R1 (audio) and R2 (calendar).

---

## Experiments (Coding Deliverables)

Built in coding phases, **after** research, with no user interaction.

### E1 — Audio Lab (`/experiments/AudioLab/`)
A small SwiftUI app implementing R1's recommendation:
- **Show streams:** live list of audio streams starting/stopping, with source-app identifiers and whatever metadata the API exposes.
- **Record stream:** record to disk in the recommended format, confirming the crash-safe streaming approach.
- Real UI for testing (system/hardware integration can't be unit-tested well).

### E2 — EventKit Lab (`/experiments/EventKitLab/`)
A small SwiftUI app implementing R2:
- Request permission (show the prompt/approve flow).
- List calendars; toggle which are included.
- Read events from the selected calendars; display participants/title/description/times.
- Produce/print the **data-availability report**. No library wrapper needed — proof-of-concept + reference code is enough.

### E3 — ArgMaxKit (`/experiments/ArgMaxKit/`)
The STT+diarization library plus a thin harness app/CLI:
- Public API roughly `processAudio(audioFile) -> transcriptObject` (final signature finalized in architecture from R3).
- Runs in the isolated worker per R3.
- Harness lets us point at a recording and inspect the rich transcript output.
- Higher test bar: unit/integration tests around the API surface and output shape.

---

## Validation (Manual Test Scripts — End of Project)

Pooled at the end so coding is never blocked. Each is a numbered script the user runs once; results recorded back into the research docs.

- **V1 (Audio):** record a real meeting (mic + another app's audio), confirm streams are detected and identified, confirm the saved file plays back at acceptable quality/size, exercise a sample-rate-change failure mode.
- **V2 (EventKit):** grant permission, confirm calendar filtering works, confirm real events load with expected fields.
- **V3 (ArgMaxKit):** run `processAudio` on a real recording, confirm Parakeet V3 + sortformer-v2-1 load on the free SDK and produce a sensible diarized transcript; sanity-check custom vocab.

---

## Out of Scope

- The core app itself (data model, tray UI, app window, search) — designed later, once this research lands.
- LLM enhancements (summaries, speaker naming, follow-ups) and any local-LLM/llama.cpp work — post-V1.
- CloudKit/iCloud sync of audio files — deferred to core-app design.
- Production hardening of the experiments; model-selection/management UI; Intel/older-macOS support.

## Known Discrepancies to Resolve in Research

- App overview specifies **Parakeet V3** (STT) + **sortformer-v2-1** (diarization); ArgMax's public README highlights whisper-large-v3 + Pyannote. Treat the app-overview models as the target and **confirm** they exist in the model library and run on the free SDK (R3).
- App overview calls Parakeet a "TTS model" — it is **STT** (speech-to-text). Terminology only.
