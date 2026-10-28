---
status: complete
---

# Implementation Plan: Live Transcript

Phases 1 to 5 prove the engine before any app work. Phase 5 ends with your engine decision; phases 6 to 11 build the feature on it. Each phase's details are in the component named in brackets. The replay harness (phase 3) and the SpeechAnalyzer session (phase 4) are kept on a separate reference branch ([`live-transcript-bench`](https://github.com/brainstencil/Biscotti/tree/live-transcript-bench)), not in the app's source.

## Phases

- [x] Phase 1: `LiveTranscriptModel` target: shared types, XPC codecs, snapshot, session protocol and the agreement reducer, with its tests [live_session]
- [x] Phase 2: `LiveTranscription` target: the Whisper session, scheduler and WhisperKit decoder, tested with a fake decoder [live_session]
- [x] Phase 3: Replay harness: `live-bench` (cost, run, path guard, paced source, simulated load), `Tools/live_bench` (fetch, fixtures, scoring, report), `make bench-live` and its hooks-mcp entry [replay_harness]
- [x] Phase 4: SpeechAnalyzer session and its harness option, starting with the permission and two-session spike [live_session]
- [x] Phase 5: Run the experiment (cost check, smoke, interval calibration, mixed vs two-track, validation and 45-minute soak); write `specs/research/live_transcription/README.md`, point `specs/research/argmax/README.md` to it, and stop for your engine decision, which sets `LiveTranscriptionDefaults` [replay_harness]
- [x] Phase 6: Live audio branch in `AudioCapture`: queue, writer hooks, `SystemWriteStep`, timeline offset and the recording-safety test; mark `ac_*` manual tests not-run [live_audio_branch]
- [x] Phase 7: Shared worker and job queue: XPC live messages, `EngineHost`, `cancelActiveWork`, `Transcriber` live client, the recording-ID queue in `TranscriptionService`; mark `tx_*` manual tests not-run. If SpeechAnalyzer was chosen, only the queue and `cancelActiveWork` are built [transcriber_worker]
- [x] Phase 8: `LiveTranscriptionService`: pump, per-recording sessions, store, drafts, snapshots, power policy, the setting and `currentUserPersonIDs`, the `openai_whisper-small` download, and AppCore wiring [live_transcription_service]
- [x] Phase 9: `TranscriptUI` and the Transcript tab: the `List` spike first, then the bubble list, item builders, following and holding still, find, reveal, and the draft, waiting and swap states in `MeetingDetailUI` [transcript_bubble_view]
- [x] Phase 10: Recording-screen drawer, toggle and level meter, language menu, find bar, note-time links, the View menu command, the Settings toggle, accessibility and the contrast test [live_drawer]
- [x] Phase 11: Hardware validation in a test build: the hardware checklist, latency signposts, visual review against the mockups in light and dark mode, and the re-run of affected manual tests [live_audio_branch, live_drawer]
