# Meeting App Bundle IDs & Audio Routing

A living reference of the process bundle identifiers (and audio-routing quirks) we
discover while testing per-process audio capture and meeting detection. We'll need
this to build a good UX later — e.g. mapping a user-facing "meeting app" to the
actual process whose audio we must tap.

**Key gotcha:** the user-facing app is often NOT the process that produces/consumes
the audio. Browsers route audio through a GPU/media helper process, and some native
apps route through a system conferencing daemon. Per-process taps must target the
*audio-producing* process, not the app icon you'd expect.

## Observed processes

| App / scenario | Audio-producing process (bundle ID / name) | Notes |
|----------------|--------------------------------------------|-------|
| Google Meet in **Safari** | `com.apple.WebKit.GPU` | Likely true for **all** Safari tabs/audio — the WebKit GPU process owns media. Can't distinguish *which* tab/site from the bundle ID alone. |
| **FaceTime** | `com.apple.avconferenced` | Audio routes through the system conferencing daemon, not the FaceTime app. During a call, output went active first on FaceTime, then input+output moved to `avconferenced` once connected. Per-process capture of FaceTime likely needs to target `avconferenced`. |

## Open questions / TODO (fill in as we test)

- Chrome (Google Meet / Zoom web): which helper process owns audio? (Chrome uses its
  own GPU/renderer helpers — expect something like a Chrome Helper process, distinct
  from Safari's WebKit.GPU.)
- Native **Zoom** app bundle ID + does it route through a helper?
- Native **Slack** huddles — process?
- **Microsoft Teams** (native + web) — process?
- Webex — process?
- Implication for UX: since Safari (and likely browser) audio is attributed to a
  single shared media process, we may not be able to per-process-tap a specific
  browser *tab*; global capture (with the meeting app focused) may be the only option
  for browser-based meetings. Confirm and document the recommended capture strategy
  per app.
