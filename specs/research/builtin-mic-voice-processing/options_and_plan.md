# Options and Proposed Plan: Built-in Mic Quality vs. VPIO (#66)

Written 2026-10-28, from the research in this folder ([summary.md](./summary.md)). This doc is a recommendation, not research. Claims here link to the research. Where something is my own reasoning rather than a researched finding, it says so.

## TL;DR

**Recommendation: turn VPIO off by default on every device, and get audio quality back in software.** On the built-in mic, VPIO and a clean meeting can't coexist. Any VPIO client puts the shared mic into raw-capsule mode. Every non-VPIO app (Chrome/Meet, Slack, very likely Teams, probably Zoom) then loses 25–30 dB, and no VPIO setting prevents it ([vpio](./vpio-side-effects/summary.md)). Four other open-source recorders hit exactly this bug and backed out of VPIO-by-default ([prior-art](./prior-art/summary.md)). So the meeting has to win, and we recover quality ourselves. We have the system track, which is the echo reference the meeting apps themselves lack.

The plan is four phases:

0. **Hardware probes:** 1–2 days, run by you.
1. **Stop breaking calls:** plain capture, mode-aware channel handling, and per-track levelling in the merge. Ship this fast.
2. **Offline echo cancellation** in the Transcription XPC, using the system track as the reference.
3. **Optional upgrades** that depend on what the probes show.

## Your questions, answered briefly

| Question | Answer |
|---|---|
| All reports on the built-in mic? A clean "if built-in, do X"? | **Nearly all.** 6 of 7 reports that name a mic are built-in (MacBook + one iMac). The odd one out is a 12-input Audient interface, which also recorded silence because VPIO's channel 0 was an empty input ([internal](./internal-evidence/summary.md)). The mechanism (raw-array switch) exists only on the built-in mic. So yes, "built-in → no VPIO" is a correct rule. But VPIO buys little on external mics: headsets have no echo, and AirPods do their own processing. VPIO also still ducks playback and forces the output reclock everywhere. **The simpler rule is "no VPIO by default, anywhere."** |
| Why Teams/Slack/Chrome? | **Not Teams-specific.** Apps that read the plain HAL stream and run their own WebRTC processing are the victims of the raw-array switch. That's confirmed from source for Chrome/Edge/Electron (which covers Slack huddles and Teams-in-browser), very likely for native Teams, and probable for Zoom. Apps that use VPIO themselves (FaceTime, Safari, Firefox) are unaffected. They cause *our* quiet-mic problem when we *don't* use VPIO ([vpio](./vpio-side-effects/summary.md)). |
| Apple's built-in beamforming without disrupting others? | **No documented way.** A plain client gets Apple's processed 1-channel stream only while no VPIO client is active, and it has no AEC. The one untested lead is per-app Mic Mode → "HAL Voice Isolation" (macOS 14+). We can open the system picker for it but can't set it (probe P1) ([array](./builtin-mic-array/summary.md)). |
| How do other apps solve it? | **Plain mic tap plus a separate system track, then software AEC using the system track as reference.** AEC runs live (anarlog/Hyprnote, Muesli), after the stop (MacParakeet, Humla), or only at the transcript level (OpenOats). AEC is skipped on headphones, and software gain fixes the level. VPIO survives only behind gates (Transcripted: consent per meeting, never while a call app is running). Commercial apps that disclose their approach use WebRTC AEC3, not VPIO. Everyone says "use headphones" ([prior-art](./prior-art/summary.md)). |
| Post-processing voice isolation? | **For echo: yes, reference AEC.** The candidates are WebRTC AEC3 (BSD-3, about 0.1% of a core) or LocalVQE v1.4-AEC (Apache-2.0, neural, built-in alignment). Track alignment decides success. **Reference-free isolation and noise suppression (Apple `AUSoundIsolation`, DeepFilterNet, RNNoise, Krisp) don't remove bleed of remote speech, and denoising before Whisper usually raises WER.** Apple has no offline or bring-your-own-reference AEC ([post-processing](./post-processing/summary.md)). |
| Multi-channel mics? | **Count channels properly** (`kAudioDevicePropertyStreamConfiguration`). Pick the channel in software, never with `AVAudioConverter`, which silently zeroes discrete layouts. Auto-detect the live channel and offer a picker (#116). For the built-in raw array: a polarity- and lag-checked sum, then gain. For a VPIO format: channel 0 only ([array](./builtin-mic-array/summary.md)). |

**Extra finding (my synthesis): the owner's three plain-tap symptoms are three separate problems, and each has a targeted fix.**

| Symptom | Likely cause | Fix |
|---|---|---|
| "Weird channels" | The built-in mic flips into 3-channel raw mode (sometimes at 44.1 kHz) whenever *any* VPIO client is active: FaceTime, Safari, possibly Teams or Zoom, or our own VPIO. | Mode-aware down-mix |
| "Wildly inconsistent levels" | (a) a 20–30 dB jump when a call starts or ends the raw mode; (b) Chrome's WebRTC AGC writing the *shared* hardware input volume (measured 0.67 → 0.27 during Meet); (c) `AudioMerger`'s global-peak scaling, which lets loud echo shrink the whole meeting about ×0.2. | Capture-side make-up gain plus offline per-track levelling |
| "Tons of echo" | No AEC on the plain path. | Reference AEC against our system track |

## Options considered

| # | Option | Fixes the call? | Our audio quality | Cost / risk | Verdict |
|---|---|---|---|---|---|
| A | Status quo (VPIO always on) | ❌ Breaks plain-HAL apps on built-in | ✅ Clean | — | Reject |
| B | Remove VPIO everywhere, no other change (PR #118 as-is) | ✅ | ❌ Voice 11–15 dB quieter, echo louder than voice, merged meeting ×0.2 (measured on #118) | Small | **Necessary, not sufficient.** Base of Phase 1 |
| C | VPIO opt-out setting, default on (PR #115) | Only for users who find the toggle | Unchanged | Small, but the default still breaks calls. Its "average all channels" kills interface mics. Keeps the silent output node | Reject as designed. An *opt-in* advanced toggle is fine for A/B during rollout |
| D | Device-conditional: built-in → plain; else VPIO | ✅ (built-in) | Built-in regresses as in B. External keeps VPIO | Keeps the reclock, ducking and route-change fragility (#88, #123, #124) on external devices, which barely need VPIO | Superseded by "plain everywhere". Cheap fallback if we want a smaller first step |
| E | Gated VPIO: use it only when a VPIO meeting app already holds the array (device has >1 input channel at start; TypeWhisper ships this) | Mostly | ✅ in that case | The meeting app can start after us. Two-VPIO bugs are still open. Teams/Zoom capture path unknown. Still ducks | Later, only if probes support it (Phase 3) |
| F | HAL Voice Isolation via per-app Mic Mode (prompt the user with the system picker) | Unknown | Possibly Apple-quality | We can't set it, only prompt. Effect on raw array untested | **Probe first (P1).** Cheap to test, potentially big win |
| G | **Offline reference AEC + per-track levelling in the Transcription XPC** | ✅ (capture is plain) | ✅ for transcripts, if alignment works | Medium. Zero capture risk. Re-runnable on old recordings. AAC-coded reference may cap cancellation | **Core of the fix (Phase 1 levelling, Phase 2 AEC)** |
| H | Capture-time AEC (PCM reference, host-time pairing) | ✅ | ✅ Best AEC input, and a clean live mic for live transcript (PR #127) | Touches the recorder; triggers the `ac_*` manual-test rule | Phase 3, if offline AEC is capped by AAC or live transcript needs it |
| I | Transcript-level dedup (drop mic words matching system words) | ✅ | Partial | Fails on double-talk. Unnecessary for today's merged pipeline | Skip (safety net only if we go per-track) |
| J | Reference-free voice isolation / NS (`AUSoundIsolation`, DeepFilterNet, RNNoise, Krisp) | ✅ | ❌ Leaves speech bleed, tends to raise Whisper WER | Medium | Reject for ASR. Maybe a listening copy later |
| K | Undo ducking via private `AudioDeviceDuck` (what Chrome and Firefox do) | Only fixes playback ducking, not the mic | — | Private API, unverified on 26/27 | Reject (moot once VPIO is off) |
| L | UX: input device + channel picker (#116), live mic meter (`RMSMonitor`, currently `micLevel: 0`), silent-track warning, "use headphones" hint | Helps | Helps | Small, independent | **Do it.** Phases 1 and 3 |

## Proposed plan

Suggested as one `/spec new project` (e.g. `mic_capture_v2`) with these phases. Phase 0 is mostly on you, because it needs real hardware.

### Phase 0: Hardware probes and a test corpus (≈1–2 days, you on your MacBook)

The goal is to settle the open questions that decide Phase 3, and to record the real mic/system pairs every later phase is measured against. An agent can write the probe harness as a ManualTestApp tab or an AudioLab target. You run it.

1. **Which apps use VPIO.** Run a 1-minute `log stream --predicate 'subsystem == "com.apple.coreaudio" OR category == "auvp"'` while native Teams, Zoom, a Slack huddle and Chrome Meet each join a call. Look for `AUVPAggregate` in that app's process. This explains which apps break, and drives gated VPIO (option E).
2. **Built-in mode census (P2/P3).** Use a plain `AVAudioEngine` tap on the built-in mic: idle, and then during each of FaceTime, Chrome Meet, Teams and Zoom. Log the channel count, rate, per-channel peak/RMS, and inter-channel lag and polarity. This settles the down-mix design, the "7 channel" question, and the size of the make-up gain.
3. **HAL Voice Isolation (P1).** Plain client, with Biscotti's Mic Mode set to Voice Isolation via the menu-bar picker, during a FaceTime call and a Chrome Meet call. Does Biscotti get levelled or isolated mono? Does the far end notice anything? A yes to both is a cheap partial win (option F).
4. **Echo corpus.** Record about 6 speaker-mode meetings (built-in mic, laptop speakers; include double-talk and a headphones control). Keep the raw tracks, and also dump a **PCM** system reference alongside the AAC one. Note your own spoken script so we can score WER.

### Phase 1: Stop breaking calls (small, ship ASAP)

1. **Plain capture by default, all devices.** Start from PR #118's removal of VPIO, `ensureOutputRateMatchesInput()`, ducking and the silent output node. Keep VPIO behind an advanced, default-off toggle for A/B during rollout. Plan to delete it later.
2. **Mode-aware channel handling** in `MicCaptureSession`:
   - **1 channel:** pass through.
   - **Built-in, more than 1 channel (raw array):** polarity- and lag-checked sum, falling back to the best single channel chosen once per session (not per buffer).
   - **Interface:** auto-detected live channel by speech-band SNR, sticky, with a dead-channel warning.
   - **Mid-recording format flips:** survive 1↔3 channels and 48↔44.1 kHz. Reuse the route-change restart machinery, and re-check whether PR #129's restart-in-place still applies once VPIO is gone.
   - **Detect built-in by UID and transport:** `BuiltInMicrophoneDevice` + `bltn`.
3. **Make-up gain before AAC encode, in raw-array mode.** Use a fixed, mode-dependent gain plus a limiter, sized from probe P2. *My reasoning, not a researched finding:* a −48 dBFS signal is at risk of being coded away by the AAC encoder's psychoacoustic model, so lift it before encoding rather than only in post. Keep it static rather than AGC, so it doesn't pump or fight Chrome's AGC.
4. **Fix `AudioMerger`.** Replace sum-then-global-peak-scale with echo-aware, speech-gated per-track normalisation and a limiter. Measure the mic's loudness only on frames where the mic is active and the system track is quiet (near-end speech), so echo doesn't drive the gain. This is cheap and has no new dependencies. It is the single biggest transcript win for the no-VPIO path ([post-processing](./post-processing/summary.md)).
5. **Wire the mic level** (`RMSMonitor`; `AudioRecorder.swift:412` hardcodes `micLevel: 0`). Show a meter and warn on a silent mic track. This catches the iD24-style all-zero recording.
6. **Process.** Mark the `ac_*` (and `tx_*`, if `Transcription` changes) manual tests `not-run`, then re-run them on hardware. Update `specs/research/audio/README.md` and the stale "VPIO" notes, since this reverses the June 2026 decision. Reply on #66, #91, #115 and #118 with the direction.

**Exit criteria:** a Chrome Meet, Teams and Slack call on the built-in mic is unaffected by starting Biscotti, as confirmed by the far end. On the Phase 0 corpus, the user's voice is within a few dB of the remote voices in the merged transcript audio.

### Phase 2: Offline echo cancellation (Transcription XPC)

1. **Alignment.** Decode both tracks. Run a coarse cross-correlation over speech-active windows (±2–3 s), repeated every N seconds to track drift and gap-fill jumps. Treat low confidence as "no echo, skip AEC"; that is usually headphones ([post-processing](./post-processing/summary.md)). Optional small capture change, best folded into Phase 1: write a per-track timeline sidecar (sample index ↔ host time, gap-fill events). That makes alignment deterministic.
2. **Engine bake-off on the Phase 0 corpus.** Compare WebRTC AEC3 (via the Sonora C API or the freedesktop build, as an SPM C target) against LocalVQE v1.4-AEC (C dylib + GGUF). Score ERLE, near-end preservation in double-talk, WER, CPU, and packaging and notarisation pain. Also compare a PCM reference with an AAC reference. *My lean:* start with AEC3, because it's mature, cheap, BSD and comes with AGC2. Switch to LocalVQE if the residual from nonlinear laptop-speaker echo is bad.
3. **Pipeline order:** align → AEC → speech-gated normalisation → merge with limiter. Keep the raw mic. The clean mic is a derived artifact with a fallback to raw. Feed Whisper the linear-AEC output if the suppressor's artifacts hurt WER.
4. **Measure:** WER and diarisation on the corpus for VPIO (old recordings), raw, raw + levelling, and raw + AEC + levelling.

### Phase 3: Optional upgrades (decided by Phase 0 and 2 results)

- **Capture-time AEC (H)** if the AAC reference caps offline AEC, or if the live transcript (PR #127) needs a clean live mic.
- **Gated VPIO (E) or Mic Mode prompting (F)** if the probes show a safe, Apple-quality path, for example "a VPIO meeting app already holds the array" or "HAL Voice Isolation works for plain clients".
- **Device and channel picker UI (#116), and a "use headphones for best results" hint** when no headphones are detected.
- **"Me" attribution from track provenance.** With a clean mic track, near-end speech is attributable to the local user. That is a product upside the merged-only pipeline can't offer.

## Interim guidance for users (post on #66 now)

- Use headphones or an external or headset mic. This avoids the built-in raw-array switch entirely.
- Unverified workaround from #66: set a *different* per-app Mic Mode for the meeting app (Voice Isolation) than for Biscotti (Standard). Report back if it works for you.

## Risks and unknowns to keep in view

- **Alignment and nonlinear laptop-speaker echo.** These are where software AEC succeeds or fails. Screenpipe got about 0 dB on real MacBook echo with a naive NLMS, while Humla got 17–21 dB offline ([prior-art](./prior-art/summary.md)). Hence the bake-off on *our* recordings before committing.
- **The quiet-mic problem returns whenever a VPIO meeting app holds the array.** This applies to FaceTime and Safari, and possibly Teams or Zoom (probe 1). Plain capture then gets raw capsules at about −48 dBFS. Make-up gain and levelling are the mitigation, and the self-noise floor sets the ceiling.
- **The Audient/iD24 mechanism is unexplained.** Channel auto-detection fixes the silent track there whatever the cause.
