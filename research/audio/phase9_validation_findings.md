# Phase 9 — Audio Capture Validation Findings (V1 / AudioLab)

Real-hardware findings from running the AudioLab experiment on an **Apple M4 MacBook Pro, macOS 15**. These validate, correct, and extend the R1 recommendation in [README.md](./README.md). Several were discovered the hard way (crashes/silence during live testing) and directly change the recommended architecture.

## Headline findings

### 1. The built-in mic on M-series (M4) MacBook Pro is a **3-channel** beamforming array
- The **default input device** on a current MacBook Pro reports **3 channels @ 48 kHz, Float32** (raw capsule feeds from the studio-quality 3-mic array), not the 1- or 2-channel mono/stereo most code assumes.
- **Impact:** any capture path that assumes mono/stereo or a fixed sample rate will break on default hardware. We hit two distinct bugs from this:
  - `ExtAudioFileWrite` `EXC_BREAKPOINT` crash — frame count was computed as `byteSize / sizeof(Float)` (correct only for mono); must be `byteSize / (sizeof(Float) * channelCount)`.
  - `Input data proc returned inconsistent 512 packets for 6144 bytes ... 4 bytes per packet` — ExtAudioFile client format was mono while the device delivered 3-ch interleaved data (6144 = 512 frames × 3 ch × 4 bytes) → every write rejected → silent file.
- **Do NOT hand-roll a downmix of the 3 raw capsules** (e.g. average them). That discards Apple's beamforming/noise-suppression and produces a *worse* signal than any normal app gets — and you don't need to: plain `AVAudioEngine` already presents the built-in array in a usable format, and `AVAudioConverter`/`AVAudioFile` handle the channel + rate conversion to mono 48 kHz. **Confirmed working** — the original plain-`AVAudioEngine` mic captured the M4 3-mic array correctly in **Test 2 (global mode)**.
- **Voice-Processing I/O was tried and is NOT the call.** VPIO (`AVAudioEngine.setVoiceProcessingEnabled(true)`, or the low-level `kAudioUnitSubType_VoiceProcessingIO` unit) is the *theoretically* ideal path — it returns beamformed, noise-suppressed, echo-cancelled mono and is what FaceTime/Zoom use. **But it failed in practice on this hardware.** Even with the built-in mic as the default input, enabling VP produced:
  - `Cannot retrieve theDeviceBoardID` + `vpStrategyManager … GetProperty` errors + `failed to run downlink DSP (state fault)` — VPIO could not initialize its tuning/DSP;
  - a bogus **9-channel / 44.1 kHz** input format (instead of clean mono);
  - constant `Input data proc returned inconsistent … packets` converter mismatches → **empty mic file**.
  It is fragile and over-engineered for what is fundamentally "record the default input" — every ordinary recording app captures the mic without hand-coding VPIO.
- **Recommendation:** capture the mic with **plain `AVAudioEngine`** — install a tap on `inputNode` using the node's *currently-queried* format and convert to mono 48 kHz for the file (the simple approach that already worked) — plus the route-change handling in finding 2. Treat VPIO as a *possible future enhancement* for built-in-mic echo cancellation, **not** a dependency, and only if it can be made to initialize reliably.

### 2. Mic capture must **survive audio route changes** — and the meeting starting *is* a route change
- Observed: with the mic on `AVAudioEngine`, **starting/accepting a FaceTime call mid-recording killed the mic** (system audio kept working). Logs showed the input device object being destroyed/rebuilt (`AudioObjectGetPropertyData: no object with given ID 199/216`), and AVAudioEngine did not recover.
- This is **not** specific to per-process capture or to our aggregate device — **any** route change (call start, AirPods connect, default-device switch) invalidates the device AVAudioEngine bound to.
- **Implication:** a meeting recorder that can't survive a route change can't record meetings, because *the meeting beginning changes the route*. Route-change survival is a hard requirement, not polish.
- **Recommendation:** handle `AVAudioEngine` `.AVAudioEngineConfigurationChange` notifications and restart/reconfigure the engine on each change (the standard, Apple-documented recovery path). On each notification the engine has stopped itself — **re-query the input format fresh** (sample rate/channel count can differ after the change; reusing the old format crashes or produces garbage), remove and reinstall the tap with the new format, and restart the engine, keeping the same output file open. This is the *entire* added complexity needed, and it is normal for any long-running recorder. (A direct-Core-Audio-IOProc approach with a `kAudioHardwarePropertyDefaultInputDevice` listener was also prototyped and **stashed** for reference, but is not needed — plain AVAudioEngine + this notification is sufficient.)
- **Tradeoff of not using VPIO:** we forgo Apple's **acoustic echo cancellation** on the mic track. Practical impact: recording on **speakers**, the remote audio (playing out loud) bleeds faintly into the **mic** track; on **headphones** there is no bleed. Since the system audio is captured on its own track regardless, this is an acceptable v1 tradeoff — mitigate by recommending headphones, or subtract echo in post. Revisit built-in-mic VPIO later *only if* diarization quality actually suffers (and only after confirming VPIO can be made to initialize reliably — see finding 1).

### 3. **Per-process capture is not worth it — use global system-audio capture**
- Per-process taps were fragile (disrupted the mic; see below) AND **useless for the most common meeting setups**:
  - **Browser meetings** (Google Meet / Zoom web in **Safari**) → all Safari audio is one shared process, **`com.apple.WebKit.GPU`**. You cannot isolate the meeting tab from other tabs.
  - **FaceTime** → audio routes through **`com.apple.avconferenced`**, not the FaceTime app.
  - (See [meeting_app_bundle_ids.md](./meeting_app_bundle_ids.md) for the running list.)
- Per-process only cleanly targets *native* apps (e.g. Zoom desktop), and even then is fragile.
- **Recommendation:** ship **global system-audio capture** (`CATapDescription(stereoGlobalTapButExcludeProcesses: [])`). Cost: notification/other-app audio leaks into the system track (minor, mitigable by suggesting Do-Not-Disturb while recording).

### 4. Two sources (mic + system) are **required**; separate tracks are the cheaper, more flexible choice
- System-audio capture alone gets the **remote** participants only — it does **not** contain the local user's voice (your mic goes to the meeting app/network, not back to your speakers). So you need **both** mic and system. This is the floor for any meeting recorder.
- **Separate tracks vs. blended:** the hard work (robust mic capture + system capture) is identical either way; blending merely *adds* a real-time, clock-drift-prone mixing step. Keeping two tracks is simpler to capture and gives diarization a free local/remote split.
- **Recommendation:** capture two tracks; treat "produce a single blended file" as an optional **post-processing** step (you can mix two into one, never un-mix one into two). Separate-vs-blended is a late, reversible output decision — not an architecture commitment.

## System-audio (Core Audio process tap) bugs found & fixed (committed; keep)
Validated and corrected against the R1 tap recipe:
- **Frame count** must divide by `sizeof(Float) * channelCount` (multichannel-safe). (commit `2e5cbcd`)
- **Aggregate device** for the tap needs, to actually route audio (otherwise silent capture + `HALC_ShellObject SetPropertyData 'nope'` / `-10877`): (commit `ffd720b`)
  - `kAudioAggregateDeviceSubDeviceListKey` containing the default **output** device UID,
  - `kAudioAggregateDeviceMainSubDeviceKey`,
  - a **distinct** aggregate device UID (do **not** reuse the tap UUID),
  - the purpose-built `CATapDescription(stereoGlobalTapButExcludeProcesses:)` / `(stereoMixdownOfProcesses:)` initializers (not bare `init()` + manual flags),
  - `tapDesc.isPrivate = true` (keep the tap private).
- Error handling: never trap on a Core Audio `OSStatus` (`logger.fault` traps in debug); surface write errors to the UI instead of crashing.

## Track-alignment finding (open)
- With **tap auto-start** (`kAudioAggregateDeviceTapAutoStartKey: true`), the system tap only delivers buffers once a tapped process actually plays audio — so the system track has **no leading silence** and starts later than the mic track → the two files are **not time-aligned**.
- **Recommendation:** capture the system track **continuously from t=0** (write silence until real audio arrives), or stamp both streams with a shared clock and pad to a common start, so `_mic.caf` and `_system.caf` are alignable for merge/diarization.

## API-choice note (still valid from R1)
- R1 chose **Core Audio taps over ScreenCaptureKit** for system audio to avoid the broad **Screen Recording** permission (scary prompt + periodic re-authorization on Sequoia), video-pipeline overhead, and SCK's immature/corruption-prone `captureMicrophone`. Validation did not contradict this; the tap path's bugs were all fixable. Keep Core Audio taps for system audio + **plain `AVAudioEngine`** for the mic (VPIO was tried and rejected — see finding 1).

## Status of the lab implementation at time of writing
- **Committed & good:** system-audio frame-count fix, silent-capture/aggregate fix. **Commit `ffd720b` is the last-good code state** — working system capture + the original plain-`AVAudioEngine` mic, before any of the mic detours.
- **Reverted/abandoned mic experiments (all turned out worse than the original simple approach):**
  - the AVAudioEngine **device-pin** hack (`ee99c84`) — fought AVAudioEngine's format negotiation, caused `-10868` format mismatches;
  - a **direct-Core-Audio-IOProc** rewrite (stashed) — worked but heavy; AVAudioEngine + the config-change notification is sufficient;
  - **VPIO** (`setVoiceProcessingEnabled`) (stashed) — faulted on the hardware (board-ID/DSP fault, bogus 9-channel input, empty mic; see finding 1).
- **Chosen approach / next:** reset AudioLab code to `ffd720b`, then add ONLY plain `AVAudioEngine` route-change handling (`.AVAudioEngineConfigurationChange` → re-query format → reinstall tap → restart engine — see finding 2). Then re-run V1: record → connect AirPods / start a call mid-recording → confirm the mic keeps recording and is non-empty; then address track alignment (open finding above).
