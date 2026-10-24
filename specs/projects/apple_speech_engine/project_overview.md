---
status: complete
---

# Apple Speech Engine

Add Apple `SpeechTranscriber` as a transcription engine option in Biscotti, beside Whisper.

- Only macOS 26+.
- New onboarding/settings UI for selecting Apple Speech vs Whisper.
- New setting for Apple Speech locale (defaults to match the user's locale, but they can edit it).
- See the attached design (`design_handoff/`, HTML; not perfect, but close). The **visuals** (the HTML artboards) are reviewed. The design **`README.md` is not reviewed**: treat its behavior and policy claims as a draft, and confirm anything controversial in the normal spec process. Where this overview and the README conflict, this overview wins.
- Custom vocabulary isn't supported on the Apple Speech model:
  - When the user tries to turn custom vocab on while using Apple Speech, they get an alert (custom vocab requires Whisper).
  - Similarly, in the model selection dialog, if switching to Apple Speech from Whisper and custom vocab is set up, show an alert confirming that it will be turned off.
- Default model: Apple Speech on macOS 26+. Whisper is the only option on macOS 15.
  - Hide "See options" in onboarding on macOS 15.
  - In Settings, let them open the dialog, but they see that Apple Speech is disabled.

## Background

- The validation experiment (`specs/projects/apple_stt_validation/results/overview.md`) passed the go/no-go gate: Apple is about 4x faster with 3–10x less engine memory, its word timings work with SpeakerKit speaker alignment, and accuracy is close to Whisper except for technical vocabulary. Output on macOS 27.0.1 was identical to macOS 26.5.2.
- Working reference code for `SpeechTranscriber` (asset install, locale, results → timed words): `experiments/STTLab`.
- Not a concern: Apple memory growth in a long-running process. Transcription runs in a temporary XPC sub-process.
