---
status: complete
---

# UI Batch — Small Fixes & Improvements

This "project" is a set of small fixes and improvements. We're using spec because I want them implemented autonomously in a batch, across many commits, without babysitting each one on its own.

## Items

- **Record button size.** Make the record button in the top right taller/bigger. One size up in Apple button sizes.

- **Repeated "RECORDING" emphasis.** The "RECORDING" button in the top right of the app and the sidebar grab too much attention when I'm on the recording screen. The same status is repeated three times with emphasis!
  - No special highlight on the sidebar — drop the red backdrop. Just a normal item like all the others, all the time (not just when on the recording screen).
  - Disable the top-right button when on the app's recording page, like we do for Home when on Home. They can see the recording icon/animation there; this becomes subtle/disabled.

- **"See All" on the homepage meetings list.** Move "See All" from the right of the title to the last row of the group-style list.
  - Label it "See All" on the left, put the count as the grey detail text before the chevron: `"See All" … "128"`.

- **Play links start playback.** When clicking a play link on the meetings page (the transcript links, or a timestamp `biscotti://…` link from notes), play the audio.
  - Previously we just seeked to time and kept the current playback state. We're revising that to "start playing if it was paused."

- **Transcribing UI.**
  - **Issue 1:** It always shows a "Downloading text to speech model" phase, even when the model is cached locally and no download is needed. It shouldn't show unless a download is needed/starting — the general "Transcribing" spinner is fine when the model is already local. Keep the fix simple: a short delay (~5s) before showing the download phase, or waiting for a real download signal, are both fine. Separately, research whether the download/cache check is itself adding latency — I'd assumed it was instant. If it's slow, we may want to migrate to "assume cached → detect failure → fall into the download path" instead.
  - **Issue 2:** The UI when transcribing in the meeting view isn't great. Text is too small, should be centred, bigger spinner. It shifts when the subtitle changes (make it a new centred line).

- **OS-wide "Command + Shift + R" shortcut** to start a recording.
  - Setting in settings to disable it. Default on, toggle.

- **Meeting list view.**
  - Allow multi-select with shift.
  - Hook up the delete key to delete a meeting. Show an alert confirmation. Support multi-delete when using multi-select.

## Plan

One phase per item (implemented autonomously), and one end phase for human review/feedback/tweaking where I review each and give sign-off. Important that each item has its own commit, in case we want to roll back.
