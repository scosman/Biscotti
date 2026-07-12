<div align="center">
<img width="84" height="84" alt="biscotti icon" src="https://github.com/user-attachments/assets/0739cc89-7ddf-4bc7-8c26-4b8cef881c5b" />

### Biscotti

**Private Meeting Transcripts for MacOS.**

[![Download for macOS](https://img.shields.io/badge/Download_for_macOS-1d1d1f?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/scosman/Biscotti/releases/latest/download/Biscotti.dmg)

</div>

---

**Biscotti** is a private and free meeting recorder for macOS. It records your meetings and turns them into accurate, speaker‑labeled transcripts and summaries. No cloud. No bot joining your call. No subscription.

<div align="center">
🔒 <strong>Private</strong> runs locally on your Mac  •  🆓 <strong>Free</strong> no account, no subscription
</div>
&nbsp;
<div align="center">
  <img width="500" height="340" alt="BiscottiHome-2" src="https://github.com/user-attachments/assets/d252ac15-e2da-41b3-ba20-36ae7de3652d" />
</div>

## Features

- 🔒 **Private by design** — recording, transcription, and AI all run on your Mac. Your data stays local.
- 🆓 **Totally free** — no account, no subscription, no upsell.
- 🧠 **Powerful AI summaries** - automatic summaries, action items, meeting titles, and real speaker names.
- 🤖 **No bots, any app** — records Zoom, Teams, Meet, FaceTime, or Slack huddles — even an in‑person conversation — without joining your call.
- 🗣️ **Knows who said what** — accurate transcripts, automatically split by speaker.
- 📅 **Calendar‑aware** — sees your upcoming meetings, offers to start recording.
- ⏹️ **Auto‑stop** — detects when your call ends and stops recording.
- ⚡ **Fast, small, native** — launches instantly, native design, built by an ex‑Apple engineer.
- 🎤 **Voice isolation** — captures your mic and everyone else as separate, clean channels. No echo.
- 📝 **Markdown notes** — jot notes in markdown, linked to the moment they happened.

## Biscotti vs. other notetaking apps

| | Biscotti | Other notetaking apps |
|---|:---:|:---:|
| Audio never leaves your Mac | ✅ | ❌ |
| Meeting notes stay private and local | ✅ | ❌ |
| No bot joins your meeting | ✅ | ❌ |
| Works with any app — even in person | ✅ | ❌ |
| Keeps full audio, not just summaries | ✅ | ❌ |
| Native Mac app, not Electron/web | ✅ | ❌ |
| Free, no subscription, no account | ✅ | ❌ |
| Lose access to your data if you stop paying | **No** | **Yes** |
| Where your data lives | **Your Mac** | **Their Cloud** |

## How it works

1. **Record** — Biscotti captures your mic and your Mac's system audio from any meeting app.
2. **Transcribe** — on‑device speech recognition produces a speaker‑labeled transcript, powered by Apple Silicon.
3. **Understand** — local AI writes a summary, pulls out action items, and figures out who's who.

Every step happens on your Mac. Your audio and transcripts never leave your Mac.

## Requirements

- A Mac with Apple Silicon (M1 or later)
- macOS 15 (Sequoia) or later
- 16GB of RAM recommended

## Install

1. Download [`Biscotti.dmg`](https://github.com/scosman/Biscotti/releases/latest/download/Biscotti.dmg).
2. Open the dmg, then copy **Biscotti.app** to your Applications folder.
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
 - Transcription powered by Whisper V3 Turbo, run by [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift)
 - Speaker identification by Pyannote, run by [SpeakerKit](https://github.com/argmaxinc/argmax-oss-swift)
 - Language models by Google Gemma 4, run on [llama.cpp](https://github.com/ggml-org/llama.cpp)

**How does it know when to suggest starting/stopping recording?**
Biscotti monitors active audio apps, without listening to their audio streams. Nothing is recorded unless you click record.

**Can I connect my calendars?**
Yes. Biscotti can sync any calendars you connect to the Apple Calendar app on your Mac. Event data enables meeting start notifications, speaker identity matching, and enhances meeting summaries.

**How does speaker idenitification work?**
Three steps: an AI model transcribes what you say, a second AI model separates speakers by voice, and a third model figures out who's who. Enhanced by calendar metadata when available.

## Built with

On‑device speech recognition and speaker identification powered by [WhisperKit and SpeakerKit](https://github.com/argmaxinc/argmax-oss-swift) from Argmax.

## License

[PolyForm Perimeter License 1.0.1](/LICENSE.md)
