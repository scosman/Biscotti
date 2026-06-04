# AudioLab Validation Script (V1)

Manual test script for the AudioLab experiment (E1). Run on a Mac with Apple Silicon running macOS 15+. You need a second device or a meeting with at least one other participant to test system audio capture.

**Results recorded below reflect a run on an Apple M4 MacBook Pro, macOS 15.** Detailed engineering findings (the bugs found and the architecture decisions they drove) live in [`research/audio/phase9_validation_findings.md`](../../research/audio/phase9_validation_findings.md).

## Key decisions recorded during this run

**Capture strategy: global system-audio capture, NOT per-process.** Per-process taps proved fragile and useless for the most common meeting setups (browser meetings in Safari all share `com.apple.WebKit.GPU`; FaceTime routes through `com.apple.avconferenced`; Slack huddles through `…slackmacgap.helper`). We ship a single global system-audio tap + plain `AVAudioEngine` for the mic. This **drops Test 3 (per-process capture)** from the active plan. See finding #3 in the findings doc.

**Audio format: 24 kHz mono, 64 kbps AAC-LC** (after substantial research + A/B testing on real recordings). 24 kHz / 64 kbps won the tradeoff: our current STT models run at 16 kHz, so 24 kHz adds **future-proofing headroom** for better models down the line, while still sounding decent and staying small. Bonus: it's pleasant enough that **playback in the UI won't hurt your ears**. See finding #5 and R1 open-question #3.

**Crash-proofing: ADTS AAC container** (no trailing table). We record into **ADTS AAC** rather than CAF/M4A so a crash preserves the audio **up to the moment of the crash**. The previous CAF/M4A containers keep a packet/index table written only at the **end** on clean close — kill the app and that table never lands, making the whole file undecodable. ADTS has **no end table**: each frame is self-describing, so a truncated file just plays up to its last complete frame. Validated by Test 5 (force-kill mid-recording → partial files still play). See finding #5.

## Prerequisites

- AudioLab built and running (via `xcodegen generate && open AudioLab.xcodeproj`, then Run)
- A meeting app installed (Zoom, Google Meet in Chrome, FaceTime, etc.)
- Headphones recommended (to avoid echo feedback during mic capture — see finding #2: without VPIO we forgo echo cancellation)

## Test Steps

### 1. Streams Tab — Process Detection

1. Open AudioLab. You should see the **Streams** tab.
2. Open a meeting app (e.g., Zoom) but do NOT join a call yet.
3. Click **Refresh**. Verify the meeting app appears in the process list with its bundle ID.
4. Join a test call (or start a FaceTime call to yourself on another device).
5. Click **Refresh**. Verify:
   - [x] The meeting app shows **Output: Active** (green dot).
   - [x] The meeting app shows **Input: Active** if it is using the mic.
   - [x] The app is highlighted as a known meeting app (blue video icon).
6. Leave the call. Click **Refresh**. Verify the app's input/output status updates.

**Result:** **PASS.** Detection works. Key learning: the user-facing app is often NOT the audio-producing process — FaceTime → `com.apple.avconferenced`, Safari meetings → `com.apple.WebKit.GPU`, Slack huddle → `com.tinyspeck.slackmacgap.helper`. Bundle IDs and routing quirks captured in [`meeting_app_bundle_ids.md`](../../research/audio/meeting_app_bundle_ids.md). **Caveat surfaced:** updates required a manual **Refresh** click — input/output state changes do not fire the process-list listener. This drove a new coding step (see **Test 8: live auto-refresh**). Remaining apps still untested for detection: native Zoom, Chrome (Meet/Zoom web), Microsoft Teams, Webex.

### 2. Record Tab — Global System Audio Capture

1. Switch to the **Record** tab.
2. Select **Global (all system audio)** capture mode.
3. Click **Start Recording**.
4. Grant microphone and system audio permissions when prompted.
5. Play some audio on your Mac (e.g., a YouTube video or music) for ~15 seconds.
6. Speak into your microphone for ~15 seconds.
7. Click **Stop Recording**.
8. Verify:
   - [x] Both file paths are shown (one `_mic.caf`, one `_system.caf`).
   - [x] Both files have non-zero sizes.
   - [x] Duration is approximately correct.
9. Open the files in QuickTime Player or another audio player.
   - [x] The `_system.caf` file contains the system audio you played.
   - [x] The `_mic.caf` file contains your voice.
   - [x] Audio quality is acceptable for voice.

**Result:** **PASS, after two bugs fixed.** (1) `ExtAudioFileWrite` `EXC_BREAKPOINT` crash — frame count must divide by `sizeof(Float) * channelCount`, not just `sizeof(Float)` (the M4 built-in mic is a **3-channel** beamforming array, not mono). (2) Silent system capture — the tap's aggregate device needed the default-output sub-device list + a distinct aggregate UID + the purpose-built `CATapDescription(stereoGlobalTapButExcludeProcesses:)` initializer. Mic captured via **plain `AVAudioEngine`** (VPIO was tried and rejected — faulted on this hardware). See findings #1 and the "bugs found & fixed" section of the findings doc.

### 3. Record Tab — Per-Process Capture  — ❌ DROPPED

**Removed from the plan.** We chose global-only capture (see "Key decision" above and finding #3). Per-process taps were fragile and could not isolate the meeting in the common browser/FaceTime/Slack cases. Not tested further.

**Result:** _N/A — descoped._

### 4. Permission Denial Detection

**Design decision (recorded):** the recorder must **never silently fail** on a missing mic permission. It preflights `AVCaptureDevice.authorizationStatus(for: .audio)` before capturing and, when denied/restricted, shows an alert and **refuses to start** (offering "Open Settings") instead of writing a silent file. Implemented in `RecordingCoordinator.startRecording` + the alert in `RecordView`.

**Re-validation steps (run after the fix):**
1. In System Settings > Privacy & Security > Microphone, revoke AudioLab's access.
2. Launch AudioLab → Record → Start Recording. Verify:
   - [x] An alert appears ("Microphone Access Needed") with an **Open Settings** button.
   - [x] Recording does **not** start (no timer, no files created).
   - [x] "Open Settings" opens Privacy & Security → Microphone.
3. Re-grant access, return to AudioLab, Start Recording. Verify:
   - [x] Recording starts normally and the mic track captures real audio.

**Result:** **PASS (after fix).** The preflight permission check works — the OS prompt appears, and on denial the app shows the alert and refuses to start instead of writing a silent file. Original pre-fix behavior was a **silent failure (matched R1 finding 6e).** With Microphone access revoked, recording "succeeded": it produced a small (~32 KB) `_mic.caf` with **no audio** and showed **no error**. There is **no usable `OSStatus`** to branch on — `throwing -10877` appears in *both* the denied and the working runs, so it is log noise, not a denial signal. The only console line unique to the denied run is `AudioObjectRemovePropertyListenerBlock: no object with given ID <n>` (the mic input device object is absent). **Fix implemented:** preflight `AVCaptureDevice.authorizationStatus` (covers the mic; the system tap has no equivalent API so it still needs the zero-buffer backstop). **Status: builds clean, pending manual re-validation (steps above).** **Dev/validation gotcha:** ad-hoc signing (`CODE_SIGN_IDENTITY: "-"`) re-signs on every build/relaunch → macOS assigns a **new TCC identity** each time, so permission grants don't persist and duplicate "AudioLab" rows pile up in the Microphone list. Production needs a stable signing identity.

### 5. Crash-Safe Recording (Optional)

1. Start a recording with some audio playing.
2. Wait 30+ seconds.
3. Force-quit AudioLab (Cmd+Q or Activity Monitor > Force Quit).
4. Re-open AudioLab.
5. Navigate to the recordings directory (shown in the file paths from a previous recording).
6. Verify:
   - [x] The `.aac` files from the interrupted recording exist.
   - [x] They are playable (partial recording up to the crash point) — via `afplay`/ffmpeg.

**Result:** **PASS after switching to ADTS AAC.** Initial attempt (AAC-LC in **CAF**) **FAILED**: the partial CAFs existed after a `kill -9` but were **undecodable** (QuickTime `-12842`, ffmpeg `Missing packet table. It is required when block size or frame size are variable.`) — AAC's variable-size packets need the CAF **`pakt`** chunk, which is written only on `close`, so a hard kill loses the whole recording. **Fix shipped:** record **ADTS AAC** (`ExtAudioFile` + `kAudioFileAAC_ADTSType`) for both tracks. ADTS frames are **self-syncing** (per-frame sync word + length), so a truncated file decodes up to the last complete frame — no packet table, no finalization. **Crash test now passes** (partial `_mic.aac`/`_system.aac` play up to the kill point). Two writer bugs were found and fixed along the way: (1) the bitrate-commit poked `ExtAudioFile` with a wrong-typed `kExtAudioFileProperty_ConverterConfig` → `EXC_BAD_ACCESS` (fixed: NULL `CFArrayRef` at pointer size); (2) the mic track came out empty because its ExtAudioFile client format was the raw 3ch/48k input while the tap wrote pre-converted mono buffers (fixed: client format = mono processing format). See headline finding #5 in the findings doc.

### 6. Long Recording Stability (Optional, ~10 minutes)

1. Start a global recording during a real meeting or with continuous audio.
2. Let it run for at least 10 minutes.
3. Stop recording.
4. Verify:
   - [x] Files are present and playable.
   - [x] No gaps or corruption in playback.
   - [x] File sizes are proportional to duration (~0.5 MB/min per stream at 64 kbps).

**Result:** **PASS.** ~10-minute global recording (music playlist out the speakers + occasional mic), user-reported **memory stable** throughout. Both tracks **decode end-to-end with zero ffmpeg errors** (no gaps/corruption): `_mic.aac` = 4.93 MB, decoded **10:06.20**; `_system.aac` = 4.87 MB, decoded **10:06.46**. **Sizes proportional:** 0.488 MB/min/stream (measured mic bitrate 64.9 kbps) — matches the ~0.5 MB/min/stream target. **Track alignment held over the long run:** the two files differ by only **~0.26 s** at the file level (a ~4 s tail seen in the UI timer — system kept capturing briefly after the mic stopped — did not appear in the decoded data; this is much tighter than the start-of-recording case in the open track-alignment finding). **Tooling gotcha:** `ffprobe` quick-estimates a wildly wrong duration for raw ADTS AAC (it misreads bitrate, e.g. reported 5.2 h / 2061 bps for the system track) — a full decode (`ffmpeg -i f -f null -`) gives the true duration.

### 7. Route-Change Survival & Zero-Buffer Detection

This covers the known Core Audio failure modes: device/route changes mid-recording, and the all-zero-buffer tap bug.

1. Start a recording.
2. Mid-recording, trigger a route change: connect AirPods, plug in headphones, OR start/accept a call (a meeting starting **is** a route change).
3. Continue recording for ~15s after the change.
4. Stop and verify:
   - [x] The **mic** track keeps recording across the route change and is non-empty.
   - [x] The **system** track keeps recording across the route change.
5. Check the console/logs for any zero-buffer detection messages.

**Result:** **PASS.** Route-change survival — the hard requirement — is fixed and validated. Critical finding (#2): starting a FaceTime call mid-recording **killed the mic** (system audio survived) — the input device object was destroyed/rebuilt and `AVAudioEngine` did not recover on its own. Fixed by handling `.AVAudioEngineConfigurationChange`: on each change, re-query the input format fresh, reinstall the tap, restart the engine, keep the same file open. Route-change survival is a **hard requirement** (the meeting beginning changes the route).

**Zero-buffer detection — DEFERRED (decision).** The all-zero-buffer tap failure (seen on macOS 26.5 beta in R1) did **not** reproduce on macOS 15 across any run here. The detection scaffolding exists (`RMSMonitor` + `SystemAudioCapture.isSuspectedFailure`) but is intentionally **left unwired** to the UI: with no reproducible failure on our target OS, wiring + forced-failure validation is a solution to a problem we don't have. **Decision: defer.** Leave the monitor in place, do not surface it, and revisit only if the all-zero tap actually appears in real use. Not a Phase 9 blocker.

**Track alignment — documented open enhancement (not a blocker).** With tap auto-start the system track has no leading silence and starts later than the mic track. Test 6 characterized this as a **start/stop edge effect, not clock drift** (the two tracks stayed within ~0.26 s over a 10-min run). A fixed t=0 anchor on both tracks closes it; tracked in the findings doc for a future pass.

### 8. Streams Tab — Live Auto-Refresh (non-polling)

_Added after Test 1 surfaced that the Streams tab required a manual Refresh. Validates the new notification-driven auto-refresh — **no polling**. Mechanism: a per-process Core Audio listener on **`kAudioProcessPropertyIsRunning`** (the `IsRunningInput`/`IsRunningOutput` variants do NOT post notifications — macOS bug, Apple Forums thread 825780); on each fire we re-read both input+output state._

1. Open AudioLab on the **Streams** tab. Do **not** touch the Refresh button for the rest of this test.
2. Open a meeting app (e.g., Zoom or FaceTime) but do not join a call. Within a second or two, verify:
   - [x] The app **appears** in the list automatically (process-list listener).
3. Join/start a call.
   - [x] The app's **Output** dot turns green **on its own**, with no manual refresh.
   - [x] The app's **Input** dot turns green **on its own** when it starts using the mic.
4. Mute/unmute or toggle mic/camera in the call; play and pause system audio (e.g., a YouTube video).
   - [~] **Known OS limitation:** transitions that start/stop ALL audio I/O update live; a mic mute/unmute *while output is still active* does NOT (the `IsRunning` boolean stays true, so no notification fires until the next full start/stop). Acceptable for meeting detection.
5. Leave the call and quit the meeting app.
   - [x] The dots go idle and the process eventually drops off the list automatically.
6. Switch away from the Streams tab and back (exercises `startMonitoring`/`stopMonitoring`).
   - [x] Auto-refresh still works after returning; no duplicate/stale rows.
7. (Stability) Leave the tab open across several call start/stops.
   - [x] No leaked listeners or growing memory; updates remain responsive.

**Result:** **PASS (user-validated live).** Streams tab updates with no manual refresh: processes appear/disappear and their active/idle dots flip on their own as calls start/stop. **Decision: notify, not poll** — registering on `kAudioProcessPropertyIsRunning` works; the input/output-specific properties are unnotifiable on macOS (forum 825780) so we re-derive I/O state on each `IsRunning` fire. One inherent OS gap (step 4: mic mute/unmute while output already active won't update live) — documented, not a blocker for meeting detection.

## Summary

| Test | Pass/Fail | Notes |
|------|-----------|-------|
| 1. Process Detection | ✅ Pass | Detection works; audio-producing process ≠ app (FaceTime→avconferenced, Safari→WebKit.GPU, Slack→.helper). Manual refresh needed → Test 8. Native Zoom/Chrome/Teams/Webex still untested. |
| 2. Global Capture | ✅ Pass | After 2 fixes (multichannel frame count; aggregate-device config). Plain AVAudioEngine mic; VPIO rejected. |
| 3. Per-Process Capture | ❌ Dropped | Descoped — global-only decision (finding #3). |
| 4. Permission Denial | ✅ Pass (after fix) | Pre-fix: silent failure (empty `_mic.caf`, no error; `-10877` is noise — fires when working too). Fix: preflight `AVCaptureDevice.authorizationStatus` → OS prompt / alert + refuse to start + Open Settings. **Validated working.** System tap has no perm API → still needs zero-buffer backstop. Ad-hoc signing churns TCC identity. |
| 5. Crash-Safe (optional) | ✅ Pass (after fix) | CAF+AAC **not** crash-safe (no `pakt` until close → undecodable after `kill -9`). Switched both tracks to **ADTS AAC** (`ExtAudioFile`, self-syncing frames) → partial files now decode up to the kill point. Fixed 2 writer bugs en route (ConverterConfig crash; empty-mic client-format mismatch). |
| 6. Long Recording (optional) | ✅ Pass | ~10 min global recording; memory stable. Both tracks decode end-to-end, zero errors; mic 10:06.20 / system 10:06.46 (aligned within ~0.26 s). 0.488 MB/min/stream (~64.9 kbps), matches target. `ffprobe` mis-estimates raw-ADTS duration → full decode for truth. |
| 7. Route-Change / Zero-Buffer | ✅ Pass | Route-change survival (the hard req) fixed & validated. Zero-buffer detection **deferred** — failure doesn't reproduce on macOS 15; `RMSMonitor` left unwired, revisit only if it ever occurs. Track-alignment is a documented edge-effect enhancement (~0.26 s/10 min), not a blocker. |
| 8. Live Auto-Refresh | ✅ Pass | User-validated live. Notify (not poll) via `kAudioProcessPropertyIsRunning` listener — the IsRunningInput/Output variants don't notify (macOS bug, forum 825780). One OS gap: mute/unmute while other direction active won't update live. |
