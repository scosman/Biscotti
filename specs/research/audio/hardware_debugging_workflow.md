# Audio hardware debugging workflow

How to diagnose, fix and validate audio-capture behaviour on real hardware. It worked well on the `audio_change_handling` work (2026-10-06): 0-byte `mic.aac`, mic/system reconnect gaps, and a false-gap-fill regression were each found, fixed and confirmed from evidence, not guesses. **Use this loop for any change to `Packages/AudioCapture`** (or other audio code), in addition to the manual-test rules in `CLAUDE.md`.

The loop:

1. **Evidence first.** Before you read code, get the facts: the recording files on disk and the unified log for that recording. Diagnose from them.
2. **Fix it, and add a test that writes real audio.** The test must go through the real format/rate path (see [Writing audio tests](#writing-audio-tests)).
3. **Build the app and give the human one specific scenario to run** ("record, unplug the mic at ~9 s, switch to AirPods, plug back at ~20 s, talk, stop").
4. **Check the result yourself.** Read the log and measure the files. Report numbers (durations, gap sizes, counts), not impressions. Compare with a clean baseline recording.
5. Repeat until the numbers are correct. A pass on the normal path does not prove a recovery path ran — check that the log line for that path is present.

---

## 1. Logging

### One-time setup (human runs it, needs sudo)

By default macOS keeps `default`/`notice`, `error` and `fault` messages, but `info` and `debug` stay only in a short memory buffer. Info lines from a recording are often gone a few minutes later. Persist them:

```
sudo log config --subsystem net.scosman.biscotti --mode "level:info,persist:info"
```

This is a prefix match, so it covers `net.scosman.biscotti.audiocapture` and the other subsystems. It creates `/Library/Preferences/Logging/Subsystems/net.scosman.biscotti.plist`. The agent cannot run `log config` (it needs root). Ask the human to run it with `! sudo …`.

### Logging rules for audio code

- Log every state change on the audio path at **`.notice` or higher**, so it persists even without the setup above: engine start/stop, route/config changes and the decision taken, reconnects, recovery, gap fills, first buffer, failures.
- Put the numbers in the message with **`privacy: .public`**: device IDs, sample rates, channel counts, `running=`/`bufferDelivered=` flags, gap seconds, frame counts. Without `.public` they show as `<private>`. Device *names* may stay private; the IDs are enough to follow a device.
- One line per event, with all the decision inputs in it. These lines made each diagnosis in this work possible:
  - `Mic setup: input=… id=137 rate=48000; output=… id=142 rate=48000; tap rate=48000 channels=2`
  - `Mic config change: running=false, bufferDelivered=false`
  - `Config-change honoured — restarting existing mic engine during startup`
  - `Mic gap fill: 2.980779s (71539 frames)` / `System gap fill: …`
- Never log on the real-time audio thread at a high rate (once per session, like `First mic buffer delivered`, is fine).

### Reading the log (agent)

- Use **`/usr/bin/log`**: in zsh, a bare `log` is a builtin and fails with `too many arguments`.
- `log show` **refuses to run in the Bash sandbox** (`log: Cannot run while sandboxed`). Run it with the sandbox disabled. It is read-only.
- The sandbox and non-sandbox `$TMPDIR` are different directories. If you save a log to a file outside the sandbox, use the absolute path (`/var/folders/…/T/…`) when you read it back.
- Useful predicates:

```
# Our capture events + AVAudioEngine lifecycle, without high-rate noise
/usr/bin/log show --style compact --info --start '2026-10-06 16:15:00' --predicate \
  '(subsystem == "net.scosman.biscotti.audiocapture" AND NOT eventMessage CONTAINS "heartbeat" AND NOT eventMessage CONTAINS "[diag]") OR (subsystem == "com.apple.avfaudio" AND process == "Biscotti" AND NOT eventMessage CONTAINS "channel layout")'

# Everything from one process in a short window (Core Audio / VPIO internals), then filter with grep
/usr/bin/log show --style compact --info --debug --start '… 13:30:16' --end '… 13:30:22' --predicate 'processID == 78689'

# Only errors/faults
… --predicate 'process == "Biscotti" AND messageType == error'
```

- `com.apple.avfaudio:avae` lines show the AVAudioEngine lifecycle and are often the key evidence: `start, was running 0`, `iounit configuration changed > stopping the engine`, `… > posting notification`, `stop, was running 1|0`. A `stop, was running 0` at user stop means the engine was already dead.
- To list unique errors in a window: `awk '$3=="E"||$3=="F"'`, then remove TIDs and hex addresses, then `sort | uniq -c`. **Compare with a clean recording** before you blame an error: most Core Audio errors are always there.

### Known benign Core Audio noise

They appear in good recordings too. Do not chase them unless the count or timing differs from a clean baseline:

| Message | Meaning |
|---|---|
| `throwing -10877`, `Error code 2003332927 reported at GetProperty`, `Cannot retrieve theDeviceBoardID string` | Property queries on elements/devices that do not support them |
| `failed to run downlink DSP` / `ProcessDownlinkAudio 'stat'` | Once per VPIO engine start, at about the first buffer |
| `Error getting channel layout from agg device on bus 1` | VPIO aggregate setup |
| `IOWorkLoop: skipping cycle due to overload`, `AUHAL stream format error` | At the moment a device is unplugged |
| `no object with given ID <n>` | Teardown removes listeners from a device that is already gone |
| `Failed expectation of constructed aggregate` | macOS rebuilds an aggregate while the device set changes |

---

## 2. Recordings on disk

- `~/Library/Application Support/Biscotti/Recordings/<UUID>/mic.aac` and `system.aac` (ADTS AAC, 24 kHz mono by default).
- **mtime is evidence.** A file's mtime is its last write. A 0-byte `mic.aac` with mtime = recording *start* while `system.aac` has mtime = recording *end* means the mic file was created and never written. This one check proved the 0-byte bug and dated its start (2026-10-01) across all recordings.
- Find the newest recording: `ls -t` (the shell may alias `ls` to `ls -l`; use `/bin/ls -t` in scripts).

## 3. Audio analysis

**`Tools/aac_track_report.py`** (no dependencies; runs in the sandbox):

```
python3 Tools/aac_track_report.py              # latest recording: durations, bytes/sec profile, mic - system
python3 Tools/aac_track_report.py <UUID>       # one recording
python3 Tools/aac_track_report.py --list 10    # summary of the latest 10
```

It parses ADTS frame headers. Each frame holds exactly 1024 samples, so `frames × 1024 / rate` is the **exact** track length. No decoding is needed.

How to use the numbers:

- **Track vs track:** `mic − system` should be within about ±0.2 s (AAC priming/padding). A clean recording here was −0.04 s.
- **Track vs wall time:** get wall time from the log (`First mic buffer delivered` → `stop, was running 1` at user stop). Each track should match it within about 0.2 s. This shows *which* track is wrong:
  - mic **short** by the reconnect gaps (−5.16 s) → gaps not filled
  - mic **long** (+0.55 s over 28.7 s ≈ 2 %) → false fills; the log then showed ~90 `Mic gap fill: 0.006s` lines in a 0.19/0.30/0.31 s cycle, which pointed to the resampler
  - system **short** (−0.98 s) after AirPods changed the output twice → system reconnect gaps not filled
- **bytes/sec profile:** a rough activity signal. Silence encodes to about 250 B/s, speech to several KB/s. Zeros mean nothing was written. A step change can show where a device changed.
- Gap fills from the log must add up: the sum of the fill lengths should equal the wall time missing from the track.

Other tools, when they are needed: `afinfo` / `afconvert` (they fail in the sandbox with `AudioFileOpenURL failed`; run them outside the sandbox), or `ffprobe`/`sox` if installed, for decoded-sample checks (RMS per window, finding digital silence runs). The human listening to the audio is still useful for quality, but alignment and duration errors are not audible on one track; measure them.

## 4. Building and handing a build to the human

- Build with `mcp__hooks-mcp__build_app` (it builds from the **main checkout**, so the code must be checked out there; see below).
- The app lands in `~/Library/Developer/Xcode/DerivedData/Biscotti-<hash>/Build/Products/Debug/Biscotti.app`. There can be several `Biscotti-*` folders (one per worktree). Pick the one whose `info.plist` `WorkspacePath` is the main checkout, and confirm the binary time (`Contents/MacOS/Biscotti.debug.dylib`) is the build you just made.
- Confirm the build has the change: `strings …/Biscotti.debug.dylib | grep -c '<new log message>'`.
- Confirm the test ran the new build: look for a log line that only the new code writes (for example `Mic setup:`).
- Tell the human: quit the installed Biscotti first. The Debug build is ad-hoc signed, so macOS may ask for mic/system-audio permission again.
- Give **one concrete scenario with timings** and the log lines that show success. Then check the logs and files yourself; do not ask the human to read them.
- Intermittent bugs need several runs in **one app process**. Report how many runs actually hit the failure condition (the log shows it), not only how many passed.

### Testing a PR or another branch

hooks-mcp runs `make` in the session's main checkout, not in a worktree. To build or test other code with it, put that code in the main checkout: switch to the branch, or `git switch --detach <commit>` on a clean tree. Switch back when done. Use a worktree for reading and diffs only.

## 5. Writing audio tests

- **Write real AAC files** through the production writer (`ExtAudioFile`, as in `MicCaptureSessionTests` / `SystemGapFillTests`), then measure the file duration. This catches both over- and under-filling.
- **Use the real hardware formats and rates, through the real converter.** The tap delivers 48 kHz; files are 24 kHz. The first gap-fill tests wrote buffers already at 24 kHz, skipped `AVAudioConverter`, and missed the false-fill bug: the resampler holds back frames between calls, so output frame counts do not match the input's host-time span. Every timing test must include a source-rate ≠ file-rate case.
- Simulate host times explicitly: contiguous buffers, jitter below the threshold, a real multi-second gap, and a gap across a tap replacement (reconnect).
- Put timing math in pure functions (`AudioFrameCount.swift`: `leadingSilenceFrameCount`, `gapSilenceFrameCount`) and test their edge cases separately.
- Compute any duration from the **same buffer** whose host time you use (input frames ÷ input rate), never from a converted output.
- Assert durations with an AAC padding tolerance (about 0.15–0.2 s), and assert fill counts (zero for continuous audio).

## 6. Case study: `audio_change_handling` (PR #101)

| Problem | How it was found | Fix | Confirmed by |
|---|---|---|---|
| 0-byte `mic.aac`, intermittent since 2026-10-01 | mtime at recording start; `avae` log: `stopping the engine` ~300 ms after start, before the first buffer; our handler ignored the notification; `stop, was running 0` at user stop | PR #94: restart the stopped engine in place; retry; fail loudly | Log: `running=false, bufferDelivered=false` → `restarting existing mic engine during startup` → `Mic startup restart completed: running=true`, then audio |
| Mic track short after unplug/replug | mic 22.87 s vs system 28.03 s; two reconnect windows in the log | Fill reconnect gaps with silence (host-clock gap) | Durations match; one `Mic gap fill` per reconnect |
| Mic track 2 % too long (regression) | mic 29.44 s vs system 28.89 s; ~90 periodic 6 ms fills in the log, starting before any reconnect | Compute duration from the input buffer, not the resampled output; threshold 5 ms → 100 ms; converter-path tests | Only reconnect-sized fills; mic 23.64 s for 23.47 s wall time |
| System track short after an output change | system 22.66 s vs mic 23.64 s after AirPods switched the output twice | Same gap fill for `LiveSystemCaptureEngine` | AirPods in and out with system audio playing: `System gap fill` 0.81 s + 0.35 s; mic 66.30 s, system 66.39 s for 66.25 s wall time |
