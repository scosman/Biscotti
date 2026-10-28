---
status: complete
---

# Live Transcript

While a meeting records, show me a live transcript, so I can glance back at what someone just said instead of waiting for the meeting to end. The goal is elegance, simplicity and Apple-like design. Notes stay the main surface; the transcript is there when I want it and out of the way when I don't.

## What I want

A transcript drawer at the bottom of the recording screen, modeled on Granola's.

- Collapsed, it is a small round waveform button at the bottom left of the notes column, with the tooltip "Show transcript". No transcript text shows until I open it.
- Open, it is a card of conversation bubbles that grows up from the button: "You" (my microphone) on the right in sage green, "Others" (system audio) on the left in warm gray. Text that may still change is gray and ends in typing dots; it turns dark when it settles.
- The toggle stays in one place: in the open drawer it sits in the footer with a down arrow and "Hide transcript". Its waveform is a green level meter while live, a spinner while starting, and gray when live transcription is unavailable.
- The footer has a language menu with two choices, "English" (best quality) and "Detect language".
- Search and copy in the header, tooltips on every icon button, and a View menu command with a shortcut.
- I can scroll back without the text jumping, select and copy while text arrives, and get back with "Return to live".
- Hiding the drawer never stops recording or transcription. Stop & Save stays where it is.
- After Stop, the drawer goes away. The meeting's Transcript tab shows the live text until the existing final pass (Whisper, then SpeakerKit) replaces it in place.

## Decisions already made

- Layout: the bottom drawer, chosen over a trailing pane, a unified timeline and a caption strip.
- Engine: Whisper, already in Biscotti, is preferred, so the feature also works on macOS 15. A smaller Whisper model and Apple's SpeechAnalyzer are tested alongside it. The spec may require macOS 26 if Whisper is not good enough; the final choice comes after the experiment, with the numbers in hand.
- Recording never depends on live transcription. The AAC files stay the source of truth, and the live path never blocks capture.
- "You" and "Others" come from transcribing the mic and system tracks separately. "You" really means this Mac's microphone.
- One transcript look: the Transcript tab of every meeting uses the same conversation bubbles as the drawer. There is no second representation.
- Questions about the meeting while it records are a separate project, `meeting_chat`, built on this one. This project provides what it needs: a frozen copy of the live transcript at a moment in time (a "snapshot"), free space to the right of the round button for a question field, and a way to open the drawer at a given time.
- No consent reminder for now.

## Technical starting points

- Prove the engine first. Replay public meeting audio (the AMI corpus) at real-time speed through each engine and hold it to four gates: latency, accuracy, endurance over a 45-minute run, and recording safety. The experiment runs the same session code the app will ship, through a `make bench-live` target modeled on `make bench`.
- Whisper only accepts 30-second inputs, so every live update runs a full-size encoder pass however little audio is new. The update interval and the model size are the cost levers; whether the cost fits during a real call is what the experiment measures.
- Live audio branches off the existing capture writer threads into bounded queues. The writers never wait for it.
- `TranscriptionService` rejects a second job today and shuts its worker down after every job. Live transcription needs one owner for the worker, a queue for final passes, and live-first priority, so back-to-back meetings work.
- This revisits `specs/research/argmax/README.md`, which recommended record-then-transcribe and deferred live captions to P2+. Keep its rule that the recorder never depends on recognition, and update its cost picture.

## Reference material

- Mockups: image-model edits of the real recording screen, used during design and not kept in the repo. Exact colors, sizes and fonts follow the design system in code.
- Investigation notes from 22 October 2026, kept outside the repo: the design, the experiment design, a meeting-chat sketch and a capture of Granola's drawer. Their content carries into this project's functional spec, UI design and architecture, which are the single source.
