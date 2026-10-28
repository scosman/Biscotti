---
status: draft
---

# Implementation Plan: Passive Mic Pipeline

**Prerequisite.** A macOS compile and test loop: either the owner's Mac connected through Remote Control, or a draft PR so CI validates each push. See [architecture §11](./architecture.md#11-execution-prerequisites-for-autonomous-implementation).

**Repo rules.** Every phase follows the repo's agent commit protocol (`precommit_checks` must be green before committing) and the manual-test staleness rule. A phase that touches `AudioCapture` marks `ac_*` `not-run`, one that touches `Transcription` marks `tx_*`, and one that touches `AudioProcessing`, the passive capture path or the lab marks `mp_*`. Phases are ordered by dependency. The two ⏸ checkpoints are human steps: `/spec implement` stops there.

## Phases

- [ ] **Phase 1: `AudioProcessing` package scaffold, `CaptureFiles` contract, and the test-signal kit.**
  - Create the new package and wire it in: Makefile `PACKAGES`, the lint/format excludes for `Vendor/`, `THIRD_PARTY_NOTICES.md` (skeleton), and the CLAUDE.md package map plus the `mp_*` staleness rule.
  - Add the `CaptureFiles` target to `AudioCapture`: `MeetingAudioFiles`, the timeline event schema, writer and reader, and `CaptureDeviceInfo`.
  - Add `AudioProcessingTestSupport`: speech fixtures, the echo, array and interface simulators, AAC round-trip, metrics, the scenario library, and `MeetingFolderWriter`.
  - Self-tests for all of the above.
  - *(architecture §1–3, §7; test_signal_kit.md; capture_passive_mic.md §CaptureFiles)*
- [ ] **Phase 2: Processing core without AEC.**
  - The decoder and input discovery.
  - Frame statistics and VAD.
  - The channel analyzer and combiner, including the overrides.
  - The leveller and peak limiter.
  - The mixer.
  - The `MeetingAudioProcessor` facade, with `echoCancellation: .off` the only working mode in this phase.
  - `ProcessingReport` and the processed-mic writer.
  - `StorageProjection` and `ProcessingVariant`.
  - `audioproc-cli process` and `inspect`.
  - Unit and integration tests on synthetic meeting folders.
  - *(audio_processing.md: stages 0, 1, 4, 5, 6, facade, CLI)*
- [ ] **Phase 3: Alignment, echo engines, and the bake-off.**
  - `TrackAligner` and `AlignmentMap`, the `EchoCanceller` protocol and factory, `EchoCancellationStage`, and `EchoMetrics`.
  - Vendor WebRTC AEC3 and LocalVQE v1.4-AEC as SPM targets under the packaging gate, time-boxed, with SpeexDSP only if both fail.
  - `audioproc-cli bakeoff` and the `make bakeoff` target.
  - Run the bake-off, commit `bakeoff_report.md`, and set `EchoCancellerFactory.defaultKind` by the F3.4 rule.
  - *(audio_processing.md stages 2–3; echo_cancellation.md)*
- [ ] **Phase 4: Passive capture.**
  - `PassiveMicCaptureEngine` becomes the default.
  - `MicCaptureSession` goes multichannel: segments, channel files, live/dead channels, gap fill on channel files, the timeline, and levels.
  - Rename the VPIO engine to `VoiceProcessingMicCaptureEngine` (mono-only mode; kept for comparison).
  - System timeline events and the optional PCM reference.
  - `CaptureOptions`, `MicCaptureMode`, `CaptureLevels`, the `CaptureState` fields, `InputDeviceProbe`, and `AudioRecorder.live(options:)`.
  - The capture-parity test against the test kit.
  - Mark `ac_*` `not-run`.
  - *(capture_passive_mic.md)*
- [ ] **Phase 5: Mic Pipeline Lab.**
  - The `MicPipelineScript` (`mp_*`) in ManualTestKit and the `ScriptShapeTests` cases.
  - The ManualTestApp Mic Lab tab: live input, record, sessions, process and compare, listen with A/B, storage, export.
  - The `WiredScripts` wiring, and the `project.yml` package additions.
  - `make build-app` must be green.
  - *(mic_pipeline_lab.md)*
- [ ] **⏸ Checkpoint 1 (human, on hardware).**
  - Run every `mp_*` step in the lab and commit `manual_test_results.json` together with any exported fixture sessions you want to keep (outside the repo, or a small selection inside it).
  - Decide, recording each decision in this file under "Checkpoint decisions":
    - the storage policy D1–D4 (F4);
    - confirm or override the echo engine (F3);
    - the production PCM reference, on or off (F5).
- [ ] **Phase 6: Integrate and finish.**
  - `Transcription`: `AudioLoading.loadAndMerge` uses `MeetingAudioProcessor`, which makes it async. Delete `AudioMerger` and `MergeTests`.
  - Playback prefers `mic.processed.aac` (`MeetingDetailUI`, via `MeetingAudioFiles.preferredPlaybackMic`).
  - Apply the Checkpoint 1 decisions:
    - the storage policy (capture flags, plus deleting channel files after processing for D2);
    - removing the losing engine's vendored code and target;
    - the production PCM reference, if chosen.
  - Docs: the audio research README and the superseded note; the CLAUDE.md stage note and Makefile table (`bakeoff`); finalize `THIRD_PARTY_NOTICES.md`.
  - `make build-app` must be green (the XPC service includes `AudioProcessing` and its resources).
  - Mark `tx_*` and `mp_*` `not-run`.
  - *(architecture §4, §7, §9; functional_spec.md F7)*
- [ ] **⏸ Checkpoint 2 (human, on hardware).**
  - Re-run `ac_*`, `tx_*` and `mp_*`, and run real meetings on the built-in mic with Chrome/Meet, Slack and Teams.
  - Confirm the acceptance criteria (functional spec §8).
  - Decide the UX: one blessed pipeline, or a setting. Then either delete `VoiceProcessingMicCaptureEngine` and the `micMode` option, or spec the setting as a follow-up.

## Checkpoint decisions

_(Filled in at the checkpoints.)_
