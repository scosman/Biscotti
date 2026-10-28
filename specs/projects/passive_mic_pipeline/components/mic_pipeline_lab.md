---
status: draft
---

# Component: Mic Pipeline Lab (ManualTestApp)

## Purpose and scope

An internal tool for testing the new pipeline live on real hardware, comparing variants by ear and by metric, and running the Checkpoint 1 experiments. Experiment results are recorded in the manual-test results file.

It is never shipped in the app. The app's user-facing UI doesn't change in this project. Requirements: [functional_spec.md](../functional_spec.md) F4, F5, F6.

## Where the code lives

```
Packages/BiscottiKit/Sources/ManualTestKit/Scripts/MicPipelineScript.swift   canonical "mic_pipeline" script (mp_* steps), placeholder closures
Packages/BiscottiKit/Sources/ManualTestKit/Scripts/AllScripts.swift          + micPipelineScript
ManualTestApp/Sources/MicLab/MicLabView.swift            the tab (sections below)
ManualTestApp/Sources/MicLab/MicLabModel.swift           @MainActor @Observable model: recorder, sessions, processing, playback
ManualTestApp/Sources/MicLab/MicLabSession.swift         session folder model + metadata.json
ManualTestApp/Sources/MicLab/LiveInputMonitor.swift      idle-time device/mode/meter polling (no recording)
ManualTestApp/Sources/MicLab/VariantRunner.swift         runs MeetingAudioProcessor variants, writes outputs, collects metrics
ManualTestApp/Sources/MicLab/StorageReport.swift         sizes + MB/hr projections for D1–D4
ManualTestApp/Sources/MicLab/LabPlayer.swift             AVAudioPlayer-based single-source player with A/B toggle
ManualTestApp/Sources/WiredScripts.swift                 + wireMicPipeline(_:) (actions/autoChecks call into MicLabModel.shared)
ManualTestApp/Sources/ScriptTabView.swift                + MicLabView tab (before the script tabs) 
ManualTestApp/project.yml                                + AudioProcessing package; products AudioProcessing, CaptureFiles
```

## Session storage

Recordings go to `~/Documents/ManualTestApp/MicLab/<yyyyMMdd-HHmmss>-<label>/`. Each holds:
- the real capture output: `mic.aac`, `mic.segK.chN.aac`, the timelines, `system.aac`, optionally `system.ref.caf`;
- `metadata.json`: label, capture options, macOS version, machine model, the free-text scenario note, and the start and stop times;
- `variants/<variantID>/`: `mix.wav`, `mic.processed.wav` and `report.json` for each processed variant.

Sessions are listed newest first. Nothing in the folder is written outside it.

## The tab: sections, top to bottom

1. **Live input.** It updates at 5 Hz whether or not a session is recording.
   - When idle, `LiveInputMonitor` polls the device facts. Those are device properties, read through `AudioCapture`'s public `InputDeviceProbe.defaultInput()` (see the capture component):
     - default input device name, UID, transport and built-in flag;
     - the stream-configuration channel count and nominal rate.

     It does **not** open the mic while idle, so the lab itself never perturbs a call.
   - While recording, it shows `CaptureState`:
     - per-channel peak meters (dBFS bars, up to 16);
     - the system RMS meter;
     - `micSuspectedSilent` as a red banner;
     - an event log tailing `mic.timeline.jsonl` and `system.timeline.jsonl` (segment starts with device and channel count, gaps, reconnects).
2. **Record.**
   - Fields:
     - Label (text);
     - Scenario note (multiline);
     - Mic mode picker: Passive (default) or Apple Voice Processing (comparison);
     - Toggles: Write channel files (on), Write PCM system reference (on by default in the lab).
   - Start/Stop button with an elapsed timer.
   - It uses `AudioRecorder.live(options:)`; a recorder is single-use, so each session gets a new one.
3. **Sessions.**
   - A list with the selected session's summary: duration, segments and channel counts, devices, and the mic mode used.
   - Buttons: Reveal in Finder, Delete, Export…. Export copies the folder to a user-chosen location, adding `README.md` generated from `metadata.json`, as a test fixture.
4. **Process and compare.** For the selected session there's a variant matrix of checkboxes:
   - Channels: Mono mix only / Best single channel (auto) / Channel plan;
   - Echo: Off / WebRTC AEC3 / LocalVQE (only engines in `EchoCancellerFactory.available`);
   - Reference: system.aac / system.ref.caf (only if it exists).

   "Run selected" processes each combination through `MeetingAudioProcessor.process` with `returnIntermediates: true` and `writeProcessedMic: false`, then writes the outputs into `variants/`. Progress is shown per variant. "Best single channel (auto)" means: run Channel plan first, take the reference channel `b` from the report, then run `singleChannel(b)`.

   A results table, one row per variant, shows these columns:
   - channel plan summary;
   - echo detected per segment;
   - ERLE estimate (dB);
   - mic speech loudness before and after levelling;
   - system speech loudness;
   - mic minus system loudness difference in the mix (an acceptance number);
   - real-time factor.
5. **Listen.** A source list:
   - raw `mic.aac`;
   - each channel file;
   - `system.aac`;
   - each variant's mic and mix;
   - a VPIO session, if one is selected as a comparison partner. The user can pick any second session to compare against.

   Play/Stop, plus an **A/B** toggle that switches between two chosen sources at the same playhead position (two players running muted and unmuted in sync, the same pattern as `AVAudioPlayerWrapper`).
6. **Storage.** For the selected session:
   - bytes per artifact and normalized MB/hr;
   - the totals projected per hour under D1 (all channel files kept), D2 (channel files deleted after processing), D3 (built-in mic: no channel files) and D4;
   - "digitally silent channels" as measured (the timeline's `deadChannels`) and "near-silent channels" (channels whose speech-band SNR, from the report, is under 10 dB) with their file sizes.

## `mic_pipeline` manual-test script (`mp_*`)

These are canonical steps in ManualTestKit; the actions and auto-checks are wired in `WiredScripts`. Steps marked `.instruction` aren't recordable (repo rule). Every `humanQuestion` result note is where the experiment data goes, so the committed results file *is* the experiment log.

| ID | Type | Text / behaviour |
|---|---|---|
| `mp_setup` | instruction | Built-in MacBook mic as the default input, speakers (not headphones) as output. Close other call apps. Open the Mic Lab tab. |
| `mp_idle_mode` | humanQuestion | "Live input (idle) shows the built-in mic. Note the channel count and rate in the note. Pass if it's detected as built-in." |
| `mp_chrome_no_disruption` | humanQuestion | "In Chrome, open webcammictest.com and record a sentence. Start a lab recording (Passive). Record the sentence again in Chrome. Does it sound identical (not quieter or hollow)? Note the channel count shown during this." |
| `mp_slack_huddle` | humanQuestion | "Join a Slack huddle with another person on the built-in mic and speakers. Start a lab recording (Passive). Do they hear any change? Note the channel count and rate shown." |
| `mp_teams_call` | humanQuestion | Same as above, for native Microsoft Teams. Also note whether the channel count changed when the call started; that tells us whether Teams uses VPIO. |
| `mp_zoom_call` | humanQuestion | Same, for Zoom. |
| `mp_facetime_call` | humanQuestion | Same, for FaceTime (expected: raw-array mode, about 3 channels). Note the channel count and levels. |
| `mp_speaker_echo_session` | action | Starts a 2-minute labelled session (Passive, channel files on, PCM reference on). The instruction text asks the user to keep the call on speakers and talk over the remote party at least twice (double-talk). |
| `mp_echo_reduced` | autoCheck | Processes `mp_speaker_echo_session` with the default engine. Passes if the ERLE estimate ≥ 10 dB **and** the mic-vs-system speech loudness difference ≤ 3 dB. The detail string gives both numbers. |
| `mp_aac_reference_ok` | autoCheck | Processes the same session with the AAC and PCM references. Passes if `ERLE_pcm − ERLE_aac < 6 dB`. The detail gives both numbers (F5). |
| `mp_engine_preference` | humanQuestion | "Listen to the AEC3 vs LocalVQE variants (A/B). Which has less echo and less damage to your voice? Answer in the note; pass = the chosen engine is acceptable." |
| `mp_mono_vs_channels` | humanQuestion | "On the FaceTime/raw-array session, compare 'Mono mix only' and 'Channel plan' (A/B plus the metrics table). Is the channel plan audibly or measurably better? Note it." (F4 Q3) |
| `mp_storage_report` | autoCheck | Uses the speaker-echo and FaceTime sessions. Always passes if the sessions exist; the detail string contains the MB/hr per artifact and the D1–D4 projections (F4 Q2). |
| `mp_headphones_session` | action | A 1-minute session with headphones as output. |
| `mp_headphones_no_aec` | autoCheck | Processes it. Passes if every segment reports `echoDetected == false`. |
| `mp_route_change` | humanQuestion | "During a recording, plug in or unplug a headset (or switch input in Sound settings). Does recording continue, and does the event log show a new segment? Does the mix sound continuous?" |
| `mp_interface_input2` | humanQuestion | "If you have a multichannel interface: mic on input 2, record. Is the mic track non-silent and the plan `.single(2)`? (Mark pass with the note 'no hardware' if not applicable.)" |
| `mp_vpio_ab` | humanQuestion | "Record the same short speaker-mode passage once with Apple Voice Processing and once with Passive, then A/B the VPIO `mic.aac` against the Passive Channel plan + default engine variant. Note your preference and why." |

**Staleness rule** (added to CLAUDE.md in Phase 1): any change to `Packages/AudioProcessing`, to `AudioCapture`'s passive path (`PassiveMicCaptureEngine`, `MicCaptureSession`, the `CaptureFiles` target), or to `ManualTestApp/Sources/MicLab` marks every recordable `mp_*` step `not-run`. Use `ResultsStore.markScriptNotRun(scriptID: "mic_pipeline", allStepIDs: recordableStepIDs(in:))`, or hand-edit the file.

## Wiring details

- **Sharing state with the script.** `MicLabModel.shared` is a single main-actor instance shared between the tab and the `mp_*` actions. Actions create sessions with fixed labels (`mp_speaker_echo`, `mp_headphones`), so auto-checks can find "the latest session with label X".
- **Auto-checks** run `VariantRunner` with the needed variants and return `CheckOutcome(passed:detail:)` with the measured numbers.
- **Concurrency.** Processing runs off the main actor; `MeetingAudioProcessor` is async. Only one recording and one processing job run at a time, and the Record and Run buttons are disabled while busy.
- **Permissions.** The tab reuses the existing `ac_request_permissions` flow. If the mic isn't authorized, Record shows a "Grant permissions in the Audio Capture tab first" message.

## Test plan

ManualTestApp has no unit-test target. Logic that's worth testing lives in testable places instead:
- the **`StorageReport` projection math** goes in `AudioProcessing` as `StorageProjection` (a pure function from file sizes, durations and the policy to MB/hr), with unit tests `storageProjection_D1toD4`;
- **variant enumeration and naming** go in `AudioProcessing` as `ProcessingVariant` (`allCombinations(available:hasPCMReference:)`), with unit test `variants_enumeration`;
- **`MicPipelineScript` structure** (non-empty id and title, exact step count, unique IDs, `mp_` prefix, recordable IDs) is covered by new cases in `Packages/BiscottiKit/Tests/ManualTestKitTests/ScriptShapeTests.swift`, mirroring the existing Audio Capture and Transcription cases.

`make build-app` builds both the app and ManualTestApp, and must succeed. The lab itself is exercised by the human at Checkpoint 1.
