# AudioLab Validation Script (V1)

Run this on a Mac with Apple Silicon running macOS 15+. You need a second device or a meeting with at least one other participant to test system audio capture.

## Prerequisites

- AudioLab built and running (via `xcodegen generate && open AudioLab.xcodeproj`, then Run)
- A meeting app installed (Zoom, Google Meet in Chrome, FaceTime, etc.)
- Headphones recommended (to avoid echo feedback during mic capture)

## Test Steps

### 1. Streams Tab -- Process Detection

1. Open AudioLab. You should see the **Streams** tab.
2. Open a meeting app (e.g., Zoom) but do NOT join a call yet.
3. Click **Refresh**. Verify the meeting app appears in the process list with its bundle ID.
4. Join a test call (or start a FaceTime call to yourself on another device).
5. Click **Refresh**. Verify:
   - [ ] The meeting app shows **Output: Active** (green dot).
   - [ ] The meeting app shows **Input: Active** if it is using the mic.
   - [ ] The app is highlighted as a known meeting app (blue video icon).
6. Leave the call. Click **Refresh**. Verify the app's input/output status updates.

**Result:** _______________

### 2. Record Tab -- Global System Audio Capture

1. Switch to the **Record** tab.
2. Select **Global (all system audio)** capture mode.
3. Click **Start Recording**.
4. Grant microphone and system audio permissions when prompted.
5. Play some audio on your Mac (e.g., a YouTube video or music) for ~15 seconds.
6. Speak into your microphone for ~15 seconds.
7. Click **Stop Recording**.
8. Verify:
   - [ ] Both file paths are shown (one `_mic.caf`, one `_system.caf`).
   - [ ] Both files have non-zero sizes.
   - [ ] Duration is approximately correct.
9. Open the files in QuickTime Player or another audio player.
   - [ ] The `_system.caf` file contains the system audio you played.
   - [ ] The `_mic.caf` file contains your voice.
   - [ ] Audio quality is acceptable for voice.

**Result:** _______________

### 3. Record Tab -- Per-Process Capture

1. Start a meeting call (Zoom, FaceTime, etc.) with another participant.
2. In AudioLab Record tab, select **Per-Process (target app)** capture mode.
3. Select the meeting app from the dropdown.
4. Click **Start Recording**.
5. Have the other participant speak for ~15 seconds.
6. Speak into your microphone for ~15 seconds.
7. Click **Stop Recording**.
8. Verify:
   - [ ] The `_system.caf` file contains the other participant's audio.
   - [ ] The `_mic.caf` file contains your voice.
   - [ ] The two streams are clearly independent (no bleed/echo).

**Result:** _______________

### 4. Permission Denial Detection

1. In System Settings > Privacy & Security > Microphone, revoke AudioLab's access.
2. Try to start recording.
3. Verify:
   - [ ] The app shows an error or detects the failure (not a silent hang).

**Result:** _______________

### 5. Crash-Safe Recording (Optional)

1. Start a recording with some audio playing.
2. Wait 30+ seconds.
3. Force-quit AudioLab (Cmd+Q or Activity Monitor > Force Quit).
4. Re-open AudioLab.
5. Navigate to the recordings directory (shown in the file paths from a previous recording).
6. Verify:
   - [ ] The `.caf` files from the interrupted recording exist.
   - [ ] They are playable in QuickTime Player (partial recording up to the crash point).

**Result:** _______________

### 6. Long Recording Stability (Optional, ~10 minutes)

1. Start a global recording during a real meeting or with continuous audio.
2. Let it run for at least 10 minutes.
3. Stop recording.
4. Verify:
   - [ ] Files are present and playable.
   - [ ] No gaps or corruption in playback.
   - [ ] File sizes are proportional to duration (~0.5 MB/min per stream at 64 kbps).

**Result:** _______________

### 7. Zero-Buffer Detection (Opportunistic)

This tests the known Core Audio zero-buffer failure mode. It may not reproduce reliably.

1. During a recording, switch audio output devices (e.g., from speakers to AirPods, or plug in headphones).
2. Check the console/logs for any zero-buffer detection messages.

**Result:** _______________

## Summary

| Test | Pass/Fail | Notes |
|------|-----------|-------|
| 1. Process Detection | | |
| 2. Global Capture | | |
| 3. Per-Process Capture | | |
| 4. Permission Denial | | |
| 5. Crash-Safe (optional) | | |
| 6. Long Recording (optional) | | |
| 7. Zero-Buffer (optional) | | |
