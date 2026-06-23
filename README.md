<div align="center">

<!-- Drag & drop your logo image here (it will center) -->

# Biscotti

**Meeting transcripts that never leave your Mac.**

[![Download for macOS](https://img.shields.io/badge/Download_for_macOS-1d1d1f?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/scosman/Biscotti/releases/latest/download/Biscotti.zip)

Requires macOS 15 (Sequoia) or later · Apple Silicon

</div>

---

Biscotti is a native macOS app that records your meetings and turns them into accurate, speaker‑labeled transcripts — entirely on your Mac. It captures audio from any app (or an in‑person conversation), transcribes it on‑device, and keeps everything private. No cloud. No bot joining your call. No subscription.

🔒 **Private** — runs entirely on your Mac  ·  🆓 **Free** — no account, no subscription  ·  🍎 **Native** — a real Mac app, not Electron

<!-- Drag & drop a demo video or screenshot here -->

## Features

- 🔒 **Private by design** — recording, transcription, and AI all run on your Mac. Nothing is ever uploaded.
- 🆓 **Totally free** — no account, no subscription, no upsell.
- 🤖 **No bots, any source** — records Zoom, Teams, Meet, FaceTime, or Slack huddles — even an in‑person conversation — without joining your call.
- 🗣️ **Knows who said what** — accurate transcripts, automatically split by speaker.
- ✨ **AI that runs locally** — automatic summaries, action items, meeting titles, and real speaker names.
- 📅 **Calendar‑aware** — sees your upcoming meetings, offers to start recording.
- 🛑 **Auto‑stop** — detects when your call ends and stops recording.
- 🎚️ **Voice isolation** — captures your mic and everyone else as separate, clean channels.
- 🪶 **Fast, small, native** — launches instantly, sips power, ~1 MB per minute. Built by an ex‑Apple engineer.
- 📝 **Markdown notes with timestamps** — jot notes during the call, linked to the moment they happened.

## Biscotti vs. other notetaking apps

| | Biscotti | Other notetaking apps |
|---|:---:|:---:|
| Audio never leaves your Mac | ✅ | ❌ |
| Meeting notes stay private and local | ✅ | ❌ |
| No bot joins your meeting | ✅ | ❌ |
| Works with any app — even in person | ✅ | ❌ |
| Keeps full audio, not just summaries | ✅ | ❌ |
| Native Mac app, not Electron/web | ✅ | ❌ |
| Free — no subscription | ✅ | ❌ |
| Lose access to your data if you stop paying | **No** | **Yes** |

## How it works

1. **Record** — Biscotti captures your mic and your Mac's system audio from any meeting app.
2. **Transcribe** — on‑device speech recognition produces a speaker‑labeled transcript, powered by Apple Silicon.
3. **Understand** — local AI writes a summary, pulls out action items, and figures out who's who.

Every step happens on your Mac. Your audio and transcripts are never uploaded.

## Requirements

- A Mac with Apple Silicon (M1 or later)
- macOS 15 (Sequoia) or later
- 16GB of RAM recommended

## Install

1. [Download `Biscotti.zip`](https://github.com/scosman/Biscotti/releases/latest/download/Biscotti.zip).
2. Unzip it and move **Biscotti** to your Applications folder.
3. Open Biscotti and follow the quick setup to grant microphone, system‑audio, and calendar access.

## FAQ

**Is it really private?**
Yes. Recording, transcription, and AI all run locally on your Mac. There's no account, and your audio and transcripts are never uploaded. It works completely offline (after downloading models).

**Does it join my meeting as a bot?**
No. Biscotti records your Mac's audio directly, so nothing appears in the call and other participants aren't notified.

**What apps does it work with?**
Anything that plays or records audio — Zoom, Microsoft Teams, Google Meet, FaceTime, Slack, Webex — plus in‑person conversations through your microphone.

**Does it cost anything?**
No. Biscotti is free, with no subscription and no account.

**Where is my data stored?**
Locally, on your Mac.

**Which AI does it use?**
All AI runs locally on your Mac.
 - Transcription powered by Whisper V3 Turbo, run by WhisperKit
 - Speaker identification by Pyannote, run by SpeakerKit
 - Language models by Google Gemma 4, run on llama.cpp

## Built with

On‑device speech recognition and speaker identification powered by [WhisperKit and SpeakerKit](https://github.com/argmaxinc/argmax-oss-swift) from Argmax.
