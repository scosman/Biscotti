---
status: draft
---

# Passive Mic Pipeline

Fix [issue #66](https://github.com/scosman/Biscotti/issues/66): Biscotti's mic capture (Apple voice processing, VPIO) disrupts other apps. On the built-in mic it makes the meeting app's mic quiet or hollow, and it ducks other apps' audio. The worst case is the built-in microphone. AirPods and USB mics are fine. The built-in mic has a fancy multi-channel array mix. Going around Apple's voice processing gives really poorly levelled audio, with a weird mix and tons of echo, because the mics are 1 cm from the speakers.

Neither current option works well:

1. **A simple tap:** we get wildly inconsistent levels, weird channels and tons of echo.
2. **VPIO:** we get clean audio, but it messes with other apps. About 5 PRs look at this, and they all trade 2 for 1: a tradeoff, not a clean win.

Research for this project: [`specs/research/builtin-mic-voice-processing/`](../../research/builtin-mic-voice-processing/summary.md).

## What to build

Build a new, better pipeline that replaces the existing one outright and works everywhere:

- Raw audio taps.
- Detect the correct mic channel reliably, and never lose data.
- Echo cancellation.
- Fix levels.

Constraints:

- Don't fall back to user settings that users need to toggle per app.
- Don't maintain two pipelines.

It should be an isolated capture module that we can unit test, import into the app, and import into the Manual Test App. In practice that's two packages: capture (the existing `AudioCapture`) and a new pure-DSP processing package.

Testing:

- Automated tests: generated files and unit tests.
- A Manual Test App screen to test live and compare.

## Decisions made while scoping

- **Two packages.** Capture writes raw audio and never interprets it. Processing is pure DSP, with no devices.
- **Processing runs offline, as part of transcription, not live.**
- **Storing all channels needs confirming in an experiment.** Store all channels separately, or merge to mono at capture time? Can we reliably mix to mono without losing data? What does each option cost in storage? Near-silent channels may be essentially free, and if so storing everything makes sense. Probe the built-in Mac mic specifically, since it's the 95% case. Guessing the channel live is bad, but we need to check the storage downside. A fallback option: store everything during capture, then merge or delete channels after processing. That's not ideal; use it only if storage requires it.
- **AAC echo reference.** The system track is the echo reference, and storing it as AAC may limit how much echo can be cancelled. Add a check to the Manual Test App to confirm it's good enough; we need that screen anyway.
- **Echo-canceller bake-off:** WebRTC AEC3 vs LocalVQE.
- **UX stays open.** It could be one new pipeline everyone gets, or a setting: Biscotti voice processing / Apple voice processing / none. The lean is one blessed option, but we'll see if a setting is needed.
- **Beamforming is accepted as the cost.** We won't reproduce Apple's beamforming. Losing VPIO for echo is recoverable; the remaining cost is a few dB of noise floor when the built-in mic is in raw-array mode.

## Approved phase plan

1. `AudioProcessing` package and a test-signal kit.
2. Channel choice, levelling and the new mixer.
3. Alignment, echo engines and the bake-off.
4. Capture: the passive raw tap.
5. ManualTestApp "Mic Pipeline Lab".
6. **Checkpoint 1 (human):** hardware experiments.
7. Integrate and finish.
8. **Checkpoint 2 (human):** on-hardware manual tests and real meetings, then the UX decision.
