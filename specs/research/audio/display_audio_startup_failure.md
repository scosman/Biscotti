# Microphone startup with external displays and a Bluetooth headset

## Reproduction and cause

Biscotti 0.3.0 could start recording without receiving microphone audio when two
Dell U2720Q DisplayPort displays and a Bose NC 700 Bluetooth headset were connected.
The headset was selected for both input and output in macOS and Teams; neither
monitor was selected as the audio output. The reporter reproduced the failure with
both connected, while the headset alone and displays without the headset worked.

Core Audio logs from 2026-09-27 show AVAudioEngine starting, then stopping after an
IO-unit configuration change. Biscotti ignored the configuration notification
because no mic buffer had arrived. The engine stayed stopped until teardown.
After three seconds, AudioRecorder treated the missing first buffer as an alignment
fallback and started system capture anyway, leaving the microphone track empty.

The application defect is the ignored **stopped** engine during startup. The reason
macOS reconfigures this particular headset/display combination remains unknown;
the evidence does not establish an incorrect device selection or a defective dock.

## Recovery

- Before the current engine delivers audio, ignore configuration changes only if
  it is still running. If stopped, keep the existing AVAudioEngine and enabled
  VoiceProcessingIO unit, re-query the input format, reinstall the input tap and
  silent output node, then prepare/start that same engine.
- After audio delivery, retain the existing full rebuild for configuration changes.
  Keep the recording file open and preserve the original alignment anchor.
- Ignore notifications from old or unrelated engine instances. Remove the observer
  on unrecoverable configuration failure before allowing a later startup attempt.
- Require a successfully written, nonempty mic buffer before starting system capture.
  If none arrives within three seconds, stop and retry mic startup once, then throw
  `micEngineFailed`. Cancellation also stops the mic and clears the callback.
- Log device IDs/rates, output-rate request results, engine running/buffer state and
  first-buffer delivery at notice level. Device names remain private. The existing
  output-rate adjustment policy is unchanged.

Preserving VoiceProcessingIO matters: an earlier candidate that fully rebuilt on
every pre-buffer stop repeatedly encountered the same stop and timed out on the
affected hardware. Restarting the existing engine recovered successfully.

## Hardware validation (2026-09-29)

The reporter tested build 20260929.2 on a MacBookPro18,1 running macOS 15.7.9
(24G830), with the Bose headset and both Dell displays connected. Two recordings
in the same app process exercised the recovery path:

| Configuration stop | Same-engine restart completes | First mic buffer |
| --- | --- | --- |
| 14:56:59.015 | 14:56:59.077 | 14:56:59.165 |
| 15:00:15.105 | 15:00:15.180 | 15:00:15.278 |

Both starts recovered without a mic timeout or repeated teardown. The second
recording lasted approximately 33 minutes. The reporter confirmed successful
recording/transcription, including their own voice and the other participants.
These observations validate recovery for the reported setup; they do not establish
coverage for every headset/display combination.

The first session's system capture began about 3.2 seconds after the first mic
buffer and applied leading-silence alignment; the reason for that delay is unknown.
At the end of the second session, a device switch caused a system-tap reconnect
failure which recovered on the next attempt. The logs alone cannot establish
gap-free audio through that switch.

Automated tests cover recorder-level first-buffer alignment, timeout/retry,
exhaustion, cleanup and cancellation. They do not emulate Apple's VPIO hardware.
**Update (2026-10-08):** the `ac_headset_startup` manual step was removed from
ManualTestApp. The recovery runs only when macOS stops the engine before the first
buffer. That happens intermittently and only on some setups (this one and the USB
setup below), so a pass on the step did not show that the recovery ran. Also, its
wording (Bluetooth headset, external displays, meeting app) did not fit
ManualTestApp. Coverage is now the automated tests and the hardware evidence in
this note. To re-check on hardware, confirm the log line `Config-change honoured —
restarting existing mic engine during startup`, followed by first-buffer delivery.
The original description of the step follows.

The `ac_headset_startup` manual step requires successful repeated recording with
both local and remote speech; an explicit startup error is a failure. The broader
AudioCapture manual suite remains marked `not-run` under the repository's staleness
rule. The targeted end-to-end hardware validation above is recorded separately.

## Review follow-up: callbacks from retired capture attempts

The hardware validation above predates this follow-up. Review identified a
conditional race: if a removed tap delivers a late callback after a retry opens
its file, shared mutable file/callback state could mistake it for the new attempt's
audio. Whether the platform delivers such a callback on the reported setup is
unverified; correctness no longer relies on callback draining during teardown.

`MicCaptureSession` now owns one attempt's file, converter and immutable first-buffer
callback. Each installed tap has its own identity. Validation, conversion, writing
and first-anchor selection share a lock with tap invalidation and file closing;
the audio callback only tries that lock and drops the buffer on contention.
Retired callbacks cannot write into or mark a replacement tap as delivering audio.
A callback already selected before close remains bound to the old attempt's stream.

Deterministic tests exercise late callbacks after close/retry and tap replacement,
verify the resulting AAC files, and check that valid replacement taps preserve
recorded audio and the session's original anchor. These tests do not activate audio
hardware. The same-engine/VPIO recovery sequence is retained, but this follow-up
has not yet been rerun on the Bose-and-displays setup.

## Second confirmed setup: USB mic + USB DAC (no Bluetooth)

A separate setup on macOS (Darwin 24.6) reproduced the same failure signature
without Bluetooth: Samson C01U USB microphone input, NuForce µDAC 2 USB DAC
output. Evidence collected 2026-10-01 to 2026-10-06 on `main` (before PR #94):

- Every 0-byte `mic.aac` had its mtime at recording start.
- Unified log showed `AVAudioEngine start` → ~300 ms later `iounit configuration
  changed > stopping the engine` → ~110 ms later `posting notification` → 3 s
  later `Mic first-buffer timeout`, and at stop `stop, was running 0`.
- Failures were intermittent (approximately half of recordings on affected days).

After PR #94, five test recordings on this setup all contained mic audio. However,
the startup engine-stop did not occur in any of them, so the same-engine restart
path has not yet been exercised on this hardware.
