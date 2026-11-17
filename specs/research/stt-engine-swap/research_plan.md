# Research Plan: Swap WhisperKit STT, Keep SpeakerKit

## Goal

Biscotti uses WhisperKit (STT) + SpeakerKit (diarization) on Argmax's free/open-source tier. The best STT models are behind Argmax's paywall, which is a no-go for a free app. Newer free models (e.g. NVIDIA Parakeet), free Apple-Silicon libraries (FluidAudio, whisper.cpp, transcribe.cpp, others) and Apple's built-in SpeechAnalyzer exist. The decision this feeds: **can we replace WhisperKit cleanly with a free library + better model while keeping SpeakerKit** (which we like, and which we hook deeper into — voice-prints, centroid embeddings, etc.)? What does each library produce, and can it be mapped to what the app needs?

Constraints that are settled and not to be re-litigated:
- Keep SpeakerKit for diarization. Prior analysis found no better post-processed diarizer; streaming diarizers are better only at streaming.
- macOS 15+, Apple Silicon only, runs in an XPC service (`XPCServices/BiscottiTranscriber`), free app — no paid SDK tiers, model licenses must allow free redistribution/use in a free app.
- Transcription is batch (after recording stops), not live.
- A split strategy is acceptable: Apple's built-in STT on newer macOS (zero app-managed downloads), a library engine on older macOS — if Apple's quality holds up. Quality, speed and energy comparisons drive that call.

Primary sources: the repo (`Packages/Transcription`, `specs/research/argmax/README.md`, `specs/architecture.md`) and upstream docs/source. `specs/projects/fluid_audio_engine/` (untracked draft from an earlier session) has useful notes but is **not** a primary source — verify anything taken from it.

## Run

- Model: Opus 5.5 (current session model) for all subtopic agents and the summary agent.

## Subtopics

- [x] App contract & SpeakerKit decoupling — what the app consumes from STT, and whether SpeakerKit can run on another engine's output
- [x] STT model landscape & Argmax paywall — which models beat what we get free today, what exactly is paywalled, licenses
- [x] FluidAudio deep dive — output shape, models, integration, mapping to our contract
- [x] Apple built-in speech APIs — SpeechAnalyzer/SpeechTranscriber and newer (macOS 26/27): quality, speed, energy, output shape
- [x] transcribe.cpp deep dive — what it is, models, output shape, integration, mapping to our contract
- [x] Other libraries — whisper.cpp, sherpa-onnx, MLX ports, other entrants

## Focus Details

### App contract & SpeakerKit decoupling

Mostly repo + Argmax source (github.com/argmaxinc/argmax-oss-swift, Argmax docs). (1) Define the **contract** the app actually needs from STT: read `Packages/Transcription` (`TranscriptResult.swift`, `InProcessTranscriptionEngine.swift`, `SegmentBuilder.swift`, `TranscriptSanitizer.swift`, `MethodResolver.swift`) and trace which fields are consumed above the package (`Packages/BiscottiKit` — DataStore, Intelligence, MeetingDetailUI, AppCore). Classify each field as must-have / nice-to-have / unused (e.g. word timings, word probability, segment confidence, noSpeechProbability, language, punctuation/casing expectations). (2) Determine exactly **how SpeakerKit couples to WhisperKit today**: does SpeakerKit depend on the WhisperKit package/types? What does `DiarizationResult.addSpeakerInfo` (or equivalent) take as input — WhisperKit `TranscriptionResult`/`WordTiming` only, or something we can construct from another engine's output? Can SpeakerKit run diarization standalone on raw audio and return a speaker timeline + embeddings? What are our deeper hooks (voice-prints, centroids, `.subsegment` strategy) and do any of them depend on WhisperKit? Is SpeakerKit (and its pyannote models) fully available on the free tier, and does dropping WhisperKit change that? (3) State what an alternative STT engine must provide for word↔speaker alignment to work well (timestamp granularity/accuracy). Out of scope: surveying STT models or libraries — other subtopics own those.

### STT model landscape & Argmax paywall

Web research. (1) What exactly does Argmax paywall vs. offer free in WhisperKit / argmax-oss-swift / Argmax Pro SDK (which models: Whisper large-v3 turbo variants, Parakeet in Argmax Pro, "Nvidia Parakeet" etc.)? What do we get free today and how good is it? (2) Survey current STT models that beat that free option for **English-first meeting transcription** with possible multilingual: NVIDIA Parakeet TDT 0.6B v2/v3, Parakeet unified/en variants, Canary (1B/flash/Qwen), Whisper large-v3-turbo, distil-whisper, Moonshine, Kyutai, IBM Granite Speech, Microsoft/Mistral (Voxtral) and any others current in 2026 — check the Hugging Face Open ASR Leaderboard. For each: WER (incl. long-form/meeting benchmarks like AMI/Earnings), punctuation & capitalization, word-level timestamps (native? quality?), confidence scores, language support/detection, long-form handling, model size/RAM, license (must allow use in a free redistributed app — flag CC-BY-NC etc.). Out of scope: which libraries run these models (other subtopics), except a one-line note where a model has an obvious single runtime.

### FluidAudio deep dive

Web + source (github.com/FluidInference/FluidAudio, its Documentation/ folder, HF model cards). Pin to the latest release and read real signatures from source (docs are known to lag). Cover: supported STT models (Parakeet TDT v2/v3, unified-en, others) and their runtime (CoreML/ANE); the exact output types of the batch ASR path (`ASRResult`, `TokenTiming` — sub-word vs word, timestamp precision, confidence range/semantics, segments?, language?); punctuation/casing behaviour per model (resolve the known doc contradiction about v3 punctuation if possible); long-audio handling (chunking for 1-hour meetings); performance; model download (custom directory? progress?); SPM integration cost (binary xcframeworks, C/C++ targets, cxx standard — signing/notarization surface in an XPC service); license of library and models; maturity/release cadence; whether its ASR can be used **without** its own diarizer alongside SpeakerKit. End with a field-by-field mapping to the app contract in `Packages/Transcription/Sources/Transcription/TranscriptResult.swift` (read it) and what glue we'd have to write. Out of scope: FluidAudio's own diarizer beyond noting it exists; other libraries.

### Apple built-in speech APIs

Web + Apple docs/WWDC sessions + independent benchmarks. macOS 27 is shipped (current date Oct 2026). The user would be happy to use Apple's built-in STT on newer OS versions (zero app-managed model downloads) and keep a library engine for older OS versions — **gated on quality**. Cover: SpeechAnalyzer / SpeechTranscriber / DictationTranscriber (macOS 26) and anything new or changed in macOS 27 (WWDC 2026). Which minimum OS version is worth trusting? Quality: WER vs Whisper large-v3/turbo and Parakeet TDT v2/v3 on long-form/meeting audio (find independent benchmarks — e.g. MacStories/Argmax/FluidInference/community comparisons — not just Apple's claims); punctuation/casing; behaviour on 1-hour files; far-field/multi-speaker audio. Speed and **energy** on M-series (RTFx, ANE use, power) vs the library options. Output shape: segments/`AttributedString` runs, word-level timestamps (`audioTimeRange`), confidence, alternatives, language selection/detection, volatile vs finalized results for file (batch) input. Model assets: are they truly zero-download (system `AssetInventory` — who downloads, when, size, offline behaviour, locale coverage)? Usability inside a non-sandboxed hardened-runtime XPC service, file-based (non-live) input, TCC/permission requirements (speech recognition permission?). Does it emit anything diarization-related, and does its output align cleanly with SpeakerKit's speaker timeline? Map the output to the app contract (`Packages/Transcription/Sources/Transcription/TranscriptResult.swift`). Out of scope: third-party libraries (other subtopics), except as benchmark comparison points.

### transcribe.cpp deep dive

Web + source. First verify exactly what "transcribe.cpp" is (repo, author, relationship to whisper.cpp/ggml, which models — Parakeet? Canary? Whisper?), and whether there is more than one project by that name. Then cover: supported models and formats; Apple Silicon acceleration (Metal/CoreML/ANE); output shape (segments, word/token timestamps and how they are derived, confidence, language detection, punctuation per model); long-audio handling; performance on M-series vs alternatives where measured; Swift integration path (C API, SPM package, xcframework, build complexity), suitability inside a hardened-runtime XPC service; license of code and models; maturity, maintenance, release cadence, community size; model download/caching control. End with a field-by-field mapping to the app contract (`Packages/Transcription/Sources/Transcription/TranscriptResult.swift`) and the glue needed to feed SpeakerKit alignment. Out of scope: other libraries.

### Other libraries

Web + source. Survey the remaining free Apple-Silicon options: whisper.cpp (Metal/CoreML; Whisper models; does it run Parakeet? token timestamps, DTW word timestamps, confidence), sherpa-onnx (Parakeet/NeMo via ONNX, Swift bindings), MLX ports (parakeet-mlx, mlx-whisper, lightning-whisper-mlx — and whether usable from Swift, e.g. mlx-swift), NVIDIA NeMo/Riva on-device options, and any other notable 2026 entrant. For each: models supported, output shape (segments, word/token timestamps, confidence, language), Swift integration path (SPM, C API, binary), performance on M-series, license, maturity/maintenance, model download/caching control, suitability inside a hardened-runtime XPC service. Map each one's output to the app contract (`Packages/Transcription/Sources/Transcription/TranscriptResult.swift`) briefly. Out of scope: FluidAudio, transcribe.cpp and Apple's built-in APIs (own subtopics); model quality comparisons beyond what's needed to say which models each library runs.
