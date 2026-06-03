# Research Summary

Steak is a macOS meeting recorder that captures audio, integrates with the user's calendar, and produces diarized transcripts -- all on-device and private. This research phase investigated the four technical pillars required before building the core app: audio capture APIs and recording strategy, EventKit calendar access, ArgMax SDK integration for speech-to-text and speaker diarization, and the permissions/entitlements matrix. The headline recommendations are: use **Core Audio process taps** (system audio) paired with **AVAudioEngine** (microphone) to record two independent AAC-LC/CAF streams; use **EventKit full-access** to snapshot calendar events into our own data model; use **WhisperKit** (`whisper-large-v3-turbo`) and **SpeakerKit** (Pyannote v4 community-1) from the free `argmax-oss-swift` SDK, running inside an **XPC service** for crash isolation; and ship as a **non-sandboxed, hardened-runtime, Developer ID-notarized** app with three narrowly scoped permissions.

## Recommendations at a Glance

| Area | Chosen Approach | Detail |
|------|----------------|--------|
| **Audio capture API** | Core Audio process taps (`CATapDescription`) for system audio; `AVAudioEngine` for mic | Avoids ScreenCaptureKit's broad Screen Recording permission and monthly re-auth. [Details](audio/README.md) |
| **Audio format & streaming** | AAC-LC, 64 kbps mono, 48 kHz, CAF container (crash-safe); convert to M4A post-recording | Two independent streams (`{id}_mic.caf` + `{id}_system.caf`), shared start timestamp. ~1 MB/min total. [Details](audio/README.md) |
| **Meeting detection** | `kAudioHardwarePropertyProcessObjectList` + known bundle-ID watchlist | Detects when meeting apps (Zoom, Teams, Chrome, etc.) start/stop using mic + speaker. [Details](audio/README.md) |
| **EventKit access** | `EKEventStore.requestFullAccessToEvents()`, snapshot-and-store into own SwiftData model | Composite key for re-linking; regex extraction of conference URLs from notes/location/url. [Details](eventkit/README.md) |
| **STT model** | `openai_whisper-large-v3_turbo` via WhisperKit (free SDK) | ~3.1 GB full-precision (2.41% WER) or ~1.3 GB quantized variant for 8 GB Macs. [Details](argmax/README.md) |
| **Diarization model** | Pyannote v4 community-1 via SpeakerKit (free SDK, ~33 MB) | Per-file speaker clustering; centroid embeddings exposed for cross-file matching. [Details](argmax/README.md) |
| **ML isolation** | XPC service (`SteakTranscriber.xpc`) with `NSXPCConnection` | Crash isolation, memory isolation, auto-relaunch by `launchd`. **Must validate XPC + CoreML in E3.** [Details](argmax/README.md) |
| **Custom vocabulary** | `promptTokens` workaround (~224 tokens); full vocab is Pro-only | Soft bias via Whisper initial prompt. API designed for seamless Pro upgrade later. [Details](argmax/README.md) |
| **Permissions** | Mic (`NSMicrophoneUsageDescription`) + System audio (`NSAudioCaptureUsageDescription`) + Calendar (`NSCalendarsFullAccessUsageDescription`) | Single entitlement: `com.apple.security.device.audio-input`. Calendar at onboarding; mic + audio on first record. [Details](permissions/README.md) |
| **Distribution** | Non-sandboxed, hardened runtime, Developer ID notarized | No App Store requirement; avoids sandbox friction with Core Audio taps. [Details](permissions/README.md) |

## Key Constraints & Decisions Already Made

- **macOS 15+ / Apple Silicon only.** Intel Macs are not supported (CoreML ANE acceleration requires Apple Silicon).
- **On-device and free.** All processing uses the free `argmax-oss-swift` SDK (MIT-licensed). No audio leaves the device. No paid SDK or cloud API in V1.
- **Parakeet V3 and Sortformer v2-1 are Pro-only.** The app_overview's original model choices are not available on the free tier. V1 uses `whisper-large-v3-turbo` (STT) and Pyannote v4 community-1 (diarization) instead -- both are genuinely capable.
- **Precision-2 rejected for V1.** pyannoteAI's Precision-2 diarization model offers ~37% better accuracy but requires commercial licensing; its default cloud path conflicts with privacy goals. The on-device Argmax Marketplace variant is the only privacy-compatible upgrade path, deferred post-V1.
- **ScreenCaptureKit rejected.** Core Audio taps use a narrower permission, avoid monthly re-auth, and require no app restart after granting. ScreenCaptureKit is kept only as a fallback for the Microsoft Teams silent-capture edge case.
- **Ad-hoc-signed, non-sandboxed experiments.** Stable bundle IDs (`com.steak.experiments.<name>`) so TCC grants persist across rebuilds. Production notarization/sandboxing is covered in R4.
- **Record first, transcribe later.** No ML models loaded during the meeting. Lightweight, rock-solid recorder; STT + diarization run post-meeting on the saved files.
- **Two-file recording preserves optionality.** Mic and system audio saved separately. Merged to mono for SDK input; separate streams enable mic-based "me" identification and potential future multi-stream SDK support.

## Decisions & Open Questions

This is a **research project**: it answers technical-feasibility questions and reports what the APIs/data give us. It does **no UI/product design** — those decisions belong to core-app design later.

### Decided (planning) — shapes the experiment builds

1. **Audio capture mode (audio): build BOTH.** AudioLab implements *both* a global system-audio tap and a per-process tap, so we can compare them on real code and behavior. The experiment is what decides the V1 recommendation — the answer may be "per-process to detect the meeting app but capture all system audio," "per-process only," or "global system audio only." We won't know until we try it.

2. **System-audio permission pre-check (permissions): silence-detection only.** No private TCC API (`TCCAccessPreflight`). Keeps the App Store path open and avoids private-API maintenance risk; the first record attempt starts the tap and detects zero-filled buffers to infer a missing grant.

3. **Whisper model variant (argmax): auto-detect.** Quantized `large-v3_turbo_1307MB` on ≤8 GB Macs, full-precision `large-v3_turbo` on 16 GB+. ArgMaxKit tests hardcode the quantized variant for reproducibility and measure both.

4. **Contacts framework (eventkit): include in the prototype to measure, decide later.** EventKitLab wires up `CNContactStore` lookup so we can quantify how much extra it yields over `EKParticipant` alone — the priority is reliable **name + email**. V1 inclusion is decided after we see the actual gain vs. the cost of a 4th permission prompt.

### Out of scope (deferred to core-app design)

Product/UX choices are not decided here — experiments only prove feasibility and report data:
event-to-recording association UX, calendar filter defaults (all-day / birthday / subscribed), recurring-series grouping, and conference phone dial-in parsing UX.

### Questions for the ArgMax team (draft — full versions in [argmax/README.md](argmax/README.md))

- **XPC + CoreML/WhisperKit compatibility (critical).** Has WhisperKit/SpeakerKit been run inside an XPC service? Known issues with ANE scheduling, `.mlmodelc` cache paths, or entitlements from a helper process? *(Validated first in E3; in-process actor is the fallback.)*
- **Centroid embedding stability + threshold.** How stable are `speakerCentroidEmbeddings` across mics/noise/quality, and what cosine-distance threshold reliably means "same speaker" (for cross-file matching)?
- **Sequential vs. parallel model loading.** Recommended order for WhisperKit→SpeakerKit on one file; any shared-state issues unloading WhisperKit before loading SpeakerKit?
- **promptTokens best practices.** Best formatting to bias recognition of proper nouns within the ~224-token window?

### Deferred (post-experiment / post-V1)

- **Opus encoding** — revisit when Apple stabilizes `kAudioFormatOpus` (macOS 16+); ~half the file size at comparable voice quality.
- **Pro SDK evaluation** — custom vocabulary and Parakeet V3 are Pro-only; evaluate licensing cost only if the `promptTokens` workaround proves insufficient.

## What's Next

With research complete, the coding phases build three independent experiments:

- **E1 -- AudioLab** (`/experiments/AudioLab/`): SwiftUI app exercising Core Audio taps + AVAudioEngine recording, stream detection, and crash-safe CAF writing.
- **E2 -- EventKitLab** (`/experiments/EventKitLab/`): SwiftUI app exercising EventKit full-access, calendar filtering, event field inspection, and conference URL extraction.
- **E3 -- ArgMaxKit** (`/experiments/ArgMaxKit/`): SPM library wrapping WhisperKit + SpeakerKit behind `processAudio(file) -> TranscriptResult`, with XPC isolation and a CLI harness.

After all three are built, a validation phase runs manual test scripts on real hardware and records results back into the research docs.
