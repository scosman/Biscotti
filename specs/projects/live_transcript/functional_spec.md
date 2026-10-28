---
status: complete
---

# Functional Spec: Live Transcript

## Scope

In scope:

- A live transcript drawer on the recording screen.
- One transcript view, conversation bubbles, used by both the drawer and every meeting's Transcript tab.
- An engine experiment that picks the live engine, and the engine itself.
- The live audio branch in capture, sharing of the transcription worker, and a Settings toggle.
- A snapshot interface that the separate `meeting_chat` project builds on.

Out of scope: meeting chat and its MCP tool (`meeting_chat` project), live text in the menu-bar popover, names for individual speakers within "Others" during recording, saving the live draft across a crash or quit, audio playback from the drawer, and a consent reminder.

## User flows

1. **Glance back.** During a call, I open the drawer, read the last few lines, and close it again. Recording never pauses.
2. **Read back.** I scroll up to find what someone said ten minutes ago. While I read back, the drawer holds still and stops updating, so nothing moves under me. "Return to live" takes me back and brings it up to date.
3. **Jump from a note.** I click the time on one of my notes ("0:50") and the drawer opens at that moment.
4. **Stop and review.** I click Stop & Save. Recording ends at once. The meeting opens, and its Transcript tab shows the live text, labeled as a draft, until the final transcript replaces it in place.
5. **Back-to-back meetings.** I start a new recording while the last meeting is still being transcribed. The new meeting gets its live transcript; the earlier meeting's final transcript waits and finishes after the new recording stops.

## The drawer

The drawer exists only while a recording is in progress and live transcription is on. UI detail follows in the UI design; behavior is fixed here.

- **States.** Collapsed is a round waveform button at the bottom left of the window. Expanded is a card of bubbles that grows upward from it, across most of the window's width; the notes move up so the note field stays just above the card, and Stop & Save stays in view. The toggle keeps its position in both states. (Wider card and moving notes chosen in UI review, 25 October 2026.)
- **Height.** Dragging the card's top edge changes its height, between 240 pt and the height that keeps Stop & Save in view; the notes follow. The height carries over to the next meeting. Double-clicking the edge restores the default height, which fits the window. VoiceOver can adjust it. (Chosen in the second UI review, 25 October 2026.)
- **First use.** The drawer starts collapsed on the first recording. After that, it opens in whatever state I last left it.
- **Hide and show.** The toggle, Esc while the drawer has focus, and View > Show Live Transcript (⌘T) show and hide it. Hiding never stops recording or live transcription.
- **Status.** The toggle's waveform shows Starting (spinner), Live (green bars moving with the audio), Catching up (live text over 10 seconds behind the audio, initial value), Paused (power or heat; see below), and Unavailable (gray bars). In the open drawer, text beside the toggle names every state except Live. The drawer never shows lag numbers. Since the second UI review (25 October 2026), Catching up shows in the drawer's header instead, as "Catching up…" with a small spinner.
- **From the start.** The live transcript covers the whole recording. Audio recorded before the live engine runs, and while it restarts or falls behind, is kept, up to 15 minutes per track, and transcribed in a catch-up mode: in long passes, in conversation order, with correct times. Then the drawer follows the speech as it happens. (Chosen in the second UI review, 25 October 2026.)
- **Search.** Highlights matches in the live text and stops following while the search field is open. Closing it returns to live if the drawer was following when it opened (hardware review, 25 October 2026).
- **Copy.** Copies the transcript so far as plain text, one line per bubble, prefixed "You:" or "Others:".
- **Language menu.** Two choices: "English", marked best quality, and "Detect language". The default is English when the Mac's language is English, and Detect language otherwise. Detect identifies the language once from the first speech and keeps it for the rest of the meeting. A change applies from that point on. The final pass keeps detecting the language on its own. With an engine that cannot detect language, the menu lists that engine's languages instead, defaulting to the Mac's language.
- **Following.** The drawer follows new text while scrolled to the bottom. Scrolling up stops following and shows "Return to live". Clicking it, or scrolling back to the bottom, resumes following.
- **Stability.** While I read back, the drawer stops updating, so the passage on screen and any selection stay put. "Return to live" applies everything that arrived meanwhile.
- **Note times.** Clicking a note's time opens the drawer scrolled to that moment and stops following.
- **Gaps.** When the live path loses a stretch of audio in which 5 s or more may have held speech, small centered text between bubbles shows the gap and its full length, "Not transcribed live · 0:12", with the tooltip "Recording continued. The saved transcript includes this part." A stretch whose lost audio was silence, or a shorter one, shows nothing; the gap stays in the live transcript. (Chosen in UI review, 25 October 2026.) Since the second UI review, the live path loses audio only beyond the 15-minute backlog, at a capture gap, or when a finish runs out of time. A stretch made only of capture gaps, such as a device switch, reads "Audio paused while switching devices · 0:07", with the tooltip "Your microphone or speakers were switching; nothing was recorded here.", because the recording has nothing there either; "Not transcribed live" stays for audio that was recorded but missed by the live transcript. (Chosen by the user in the hardware review, 25 October 2026.)
- **Free slot.** The space to the right of the collapsed button stays empty, reserved for `meeting_chat`.

## One transcript view

The drawer and the Transcript tab of every meeting show the same conversation of bubbles. This replaces today's row list (`MeetingDetailUI`'s `TranscriptListView`) for all meetings, including ones recorded before this feature and imported ones.

- **Sides.** "You" bubbles sit on the right in pale sage green. Everyone else's sit on the left in warm gray. No bubble is wider than about three-quarters of the column. With one mixed track, every bubble sits on the left and names no speaker: no label, no copy prefix, no speaker in VoiceOver.
- **Labels.** Above each run of bubbles from one speaker, a small label shows the name and start time: "Priya · 0:31" on the left, "You · 0:38" on the right. Names keep today's speaker colors.
- **Bubbles.** A new bubble starts at a change of speaker or at a pause. A live bubble also ends when the other side starts speaking, at a sentence end once it is about 8 s long, and at a word once it reaches about 20 s, so the two sides interleave in time order like a chat. (Chosen in UI review, 25 October 2026.)
- **Live text.** Settled text is dark. The tail that may still change is gray and ends in three animated dots.
- **Saved meetings keep today's actions.** Clicking a speaker's name opens the speaker-mapping sheet. Clicking a time, or the play button that appears when hovering a bubble, plays from there in the meeting's audio player. In the drawer, names and times are plain text, because there is no playback during recording.
- **Selection and copy.** Text selects within one bubble, as today. The tab's Copy button copies the whole transcript as plain text with speaker prefixes.
- **Long transcripts.** The view must stay as light as today's recycling list: no memory regression on multi-hour meetings.
- **Accessibility.** VoiceOver reads each bubble with its speaker ("You: …"), reads settled text, and announces no tail changes. With Differentiate Without Color on, the tail also gets a dotted underline. Insertions do not animate.

### Who is "You" in a saved meeting

During recording, "You" is simply the microphone track, because the live engine transcribes the two tracks separately.

The saved transcript is made differently, on purpose. The final pass sums both tracks into one mix before Whisper and SpeakerKit run ([InProcessTranscriptionEngine.swift:86–104](../../../Packages/Transcription/Sources/Transcription/InProcessTranscriptionEngine.swift#L86)), so its lines know speakers ("Speaker 0", or a person's name), not tracks. This project keeps that pipeline unchanged.

Biscotti already knows who you are as a person. The `speaker_embeddings` project lets you tag yourself like anyone else, and voiceprints then recognize you in later meetings; it chose to have no "me" flag and no microphone-loudness signal ([functional spec §4 and §12](../speaker_embeddings/functional_spec.md)). Each meeting's calendar snapshot already records which person is the current user (`CalendarSnapshot.currentUserPersonID`).

So in a saved meeting, a speaker's bubbles go on the right when that speaker is tagged as you, meaning a person that any calendar snapshot marks as the current user. Everyone else, and any speaker not yet tagged or recognized, sits on the left with their name. This needs no new flag, no new setting and no change to the final pass. If Biscotti has never seen you in a calendar event, every saved bubble sits on the left.

At the swap from draft to final, your bubbles move to the left if the final transcript has not recognized you yet, and back to the right once you are tagged or recognized.

## When the meeting ends

- Stop & Save ends the recording at once, and the recording indicator turns off. The live engine finishes its last words in the background, with a time limit; it never holds the recording open.
- The meeting opens as it does today. Its Transcript tab shows the live text at once, under a "Draft · final transcript in progress" label, with the "You" and "Others" sides from the live transcript. The live engine's last words join the draft as they finish.
- When the final pass finishes, its transcript replaces the draft in place and the view keeps my position by time. If I have selected text in the transcript at that moment, the swap waits until I leave the transcript; the final transcript is already saved.
- If the final pass fails, the draft stays, labeled as a draft, and today's retry from the audio files is available.
- The draft lives only in memory. If the app quits or crashes before the final pass finishes, the draft is gone; the final transcript still runs from the audio files, as today.

## Settings and defaults

- **Live transcript toggle** in Settings → General, described as "Show a live transcript while recording". It is on by default, except on Macs with 8 GB of memory or less, where it starts off.
- **Turning it off during a recording** stops live transcription and removes the drawer. The recording continues.
- **Turning it on during a recording** starts live transcription from that moment. The drawer marks the start: "Live transcript started at 4:12".
- **Custom vocabulary** applies to live transcription with every engine that supports it. Today that is Whisper. Apple documents custom phrases only for `DictationTranscriber`, not for the `SpeechTranscriber` this project would use, so the experiment checks whether it works there.
- **Preparation.** After an install, an update or a model download, while nothing records, Biscotti loads the live model and the final pass's model once in the background, so macOS compiles them for the Neural Engine before the first meeting and the live transcript starts in seconds. Settings shows "Preparing live transcript…" meanwhile. A recording or a final pass stops it at once; what it did not prepare runs again later. It downloads nothing and runs once per update. (Chosen in UI review, 25 October 2026.) The compiled model did not last: macOS deletes it when the disk runs low, so each start compiled again. Since the second UI review, while the live transcript is on, Biscotti keeps the live model loaded (about 0.2–0.3 GB) on Macs with more than 8 GB of memory, so a live start takes seconds; a recording that starts while the live model loads waits for that load instead of stopping it. It stays loaded during the final transcription too, about 0.3 GB on top of the final model, which is unloaded when the transcription ends; it loads again after a crash. (Chosen by the user on 25 October 2026.)
- **Low disk space.** macOS deletes the prepared speech models when the startup disk runs low, so the next start prepares them again, for minutes. When a model load runs long (10 s into a live start, 15 s into the final transcription's model load) and less than 20 GB is free, Biscotti says so: in the drawer during a slow live start ("Your Mac is low on disk space, so macOS removed the prepared speech model…"), in the final transcription's status ("Taking longer: your Mac is low on disk space"), and in Settings, with a warning while the disk is low. A slow live start on a disk with room says the model is being prepared and the transcript will catch up from the start. (Chosen by the user on 25 October 2026.)
- **Low Power Mode** makes live text update less often, with no visible change. At a serious heat level, live transcription pauses and the status reads "Paused while the Mac cools down"; it resumes on its own. Recording is never affected.

## Engines and the experiment

The first deliverable is an experiment, not UI.

- A replay harness runs public meeting audio (the AMI corpus) at real-time speed through three options: the current Whisper model, a smaller Whisper model, and Apple's SpeechAnalyzer. It runs as `make bench-live`, a non-gating target modeled on `make bench`, with a matching hooks-mcp entry so agents can run it.
- The harness drives the same session code the app will ship.
- The harness and the SpeechAnalyzer session are kept on a separate reference branch ([`live-transcript-bench`](https://github.com/brainstencil/Biscotti/tree/live-transcript-bench)), not in the app's source; the app ships only the Whisper engine.
- Four gates decide:

| Gate | Passes when |
|---|---|
| Latency | 95% of words appear within 3 s of being spoken and settle within 5 s. Passing only 5 s and 8 s is a "slower live transcript" tier, reported as such. |
| Accuracy | Word error rate at most 20%, and no more than 3 points worse than the final pass on the same clips. At least 95% of a fixed list of names, numbers and negations survive. |
| Endurance | Over 45 minutes with simulated call load, the live text never falls further and further behind, added memory stays under 3 GB on a 16 GB Mac, and the Mac never stays at a serious heat level. |
| Recording safety | With live transcription on, the recording loses no audio and the two tracks stay aligned. |

- Selection: the current Whisper model if it passes; the smaller Whisper model if only cost failed; SpeechAnalyzer if no Whisper option passes, in which case the drawer requires macOS 26. If Whisper passes only the slower tier and SpeechAnalyzer passes the faster one, I decide with the numbers.
- Results go to `specs/research/live_transcription/README.md`, and `specs/research/argmax/README.md` gets a pointer that updates its "live captions P2+" note.

## Rules

1. Recording comes first. Live transcription never blocks or slows capture, and the recording survives any live-engine failure.
2. Speech is never lost silently. Missing coverage is recorded as a gap, and the transcript marks each one that may have held speech for 5 s or more. The recording and the saved transcript are always whole.
3. Settled text never changes during the recording. The final transcript may differ.
4. Results from an earlier recording never appear in a later one.
5. The live transcript is never saved as its own transcript version. Each meeting saves one version, from the final pass.
6. Everything stays on the Mac.

## Sharing the transcription worker

- Live transcription comes first. No final pass runs while a recording is in progress.
- Final passes queue instead of failing with "Another transcription is already in progress."
- A recording that starts during another meeting's final pass cancels that pass and puts it back at the front of the queue. That meeting's Transcript tab shows "Waiting to finish until the current recording stops", and the pass restarts from its audio files after the recording.

## Snapshot interface for other features

Other features read the live transcript through a snapshot: a frozen copy at one moment, holding the session, revision, how far the transcript reaches (transcribed and settled), the bubbles with their source, time range, text and settled state, the gaps, and whether the unsettled tail is included. Taking one is instant. The drawer also accepts a request to open at a given time. `meeting_chat` uses both.

## Edge cases

- **No transcription model downloaded:** the toggle shows Unavailable; its tooltip and the drawer say the model is needed and link to where to download it.
- **Language not supported by the engine:** Unavailable, with the reason.
- **SpeechAnalyzer chosen and the Mac runs macOS 15:** no drawer and no toggle in Settings.
- **System audio permission denied:** only "You" bubbles appear. Today's system-audio warning banner stays as it is.
- **Audio route change mid-meeting** (for example, AirPods connect): live text continues; any lost stretch shows as a gap.
- **Live engine crash:** Biscotti restarts the live session once; the new session first transcribes what the crashed one had not finished, so nothing is lost (second UI review, 25 October 2026). If that fails, the status becomes Unavailable ("Live transcript stopped"), and recording and the final pass continue as usual.
- **Very long meetings:** retained audio stays bounded; the bubble view stays light (see "Long transcripts").

## Constraints

- Apple silicon. macOS 15 and later with Whisper; macOS 26 and later if SpeechAnalyzer is chosen, with the app's deployment target staying at macOS 15.0.
- Only dependencies with free terms: no subscription, fee, license key or registration.
- The gates above are the performance requirements.

## Open questions

1. **⌘T.** The app has no ⌘T today (only ⌘, ⌘F and ⌘Q). In apps with a Format menu, ⌘T opens the font panel; Biscotti has none. Implementation confirms no system menu claims it.
