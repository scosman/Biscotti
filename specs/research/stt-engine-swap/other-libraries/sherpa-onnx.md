# sherpa-onnx (k2-fsa) — ONNX Runtime, many models, official SwiftPM since July 2026

Researched 2026-10-21. Pinned to **v1.13.8** (2026-09-10).

## Status

- [k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), Apache-2.0, 15.4k stars, pushed daily. Release cadence is about weekly (v1.13.5 08-11, v1.13.6 08-18, v1.13.7 09-01, v1.13.8 09-10) ([releases API](https://api.github.com/repos/k2-fsa/sherpa-onnx/releases)).
- Runtime: ONNX Runtime (via the [csukuangfj/onnxruntime-libs](https://github.com/csukuangfj/onnxruntime-libs) SwiftPM package, pinned `exact: "1.28.2"`).

## Models relevant to us

From [NeMo transducer models](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/offline-transducer/nemo-transducer-models.html) (int8 exports):
- `sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8`: English, "supports punctuations and cases".
- `sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8`: 25 European languages.
- `sherpa-onnx-nemo-parakeet-unified-en-0.6b-int8-non-streaming`: English, punctuation and case.
- Plus NeMo CTC, Whisper, Moonshine v2, SenseVoice, Qwen3-ASR, Cohere Transcribe, FireRed, Omnilingual and more (Swift example files in [swift-api-examples/](https://github.com/k2-fsa/sherpa-onnx/tree/master/swift-api-examples)).
- Parakeet Ultra (Moondream) is recognized by the new frontend in PR #4024.

### Accuracy caveat (fresh, unreleased fix)

[PR #4024](https://github.com/k2-fsa/sherpa-onnx/pull/4024) "fix: align Parakeet TDT v3 and Ultra with current NeMo preprocessing" (merged **2026-10-20**, after v1.13.8). Before it, sherpa-onnx used a different mel frontend (Povey window, 7600 Hz mel edge, other differences). On quiet audio "the existing frontend produces an empty transcript". **Releases up to v1.13.8 have a non-NeMo frontend for v3. Wait for v1.13.9+ or pin a commit.** Related: [#3999](https://github.com/k2-fsa/sherpa-onnx/pull/3999) (NeMo log-zero guard, 2026-09). Open: [#3657](https://github.com/k2-fsa/sherpa-onnx/pull/3657) "Fix modified_beam_search hallucination/empty text for NeMo TDT".

## Output shape

C struct `SherpaOnnxOfflineRecognizerResult` ([c-api.h](https://github.com/k2-fsa/sherpa-onnx/blob/master/sherpa-onnx/c-api/c-api.h)):
- `text`
- `timestamps` ("Optional token timestamps in seconds ... parallel to tokens_arr")
- `tokens_arr`, `count`
- `durations` ("Optional token durations in seconds")
- `ys_log_probs` ("Optional token log probabilities")
- `lang`, `emotion`, `event`
- `segment_timestamps` / `segment_durations` / `segment_texts_arr` / `segment_count`
- `json`

The Swift wrapper `SherpaOnnxOfflineRecognitionResult` ([SherpaOnnx.swift](https://github.com/k2-fsa/sherpa-onnx/blob/master/swift-api-examples/SherpaOnnx.swift)) exposes `text`, `tokens`, `timestamps`, `durations` ("Non-empty for TDT models"), `lang` ("For SenseVoice models"), and segment fields ("for Whisper with segment timestamps enabled"). **It does not expose `ys_log_probs`.** That field is still reachable through `result.pointee.ys_log_probs` (the class keeps a public `result: UnsafePointer<SherpaOnnxOfflineRecognizerResult>`). Kotlin has a matching open request: [#3638](https://github.com/k2-fsa/sherpa-onnx/pull/3638) "Surface ys_log_probs on OfflineRecognizerResult".

For Parakeet TDT that means:
- **Sub-word token timestamps plus durations, in seconds.** Words are rebuilt by joining tokens on the SentencePiece `▁` marker.
- Per-token log-prob (C-level only). Convert with `exp()` to get a 0–1 probability.
- No language ID (`lang` is for SenseVoice). No segments for Parakeet. No no-speech probability.

## Long audio

The offline recognizer takes whatever you pass it, but the Parakeet ONNX export has no local-attention switch that I could find. The documented pattern for long files is **Silero VAD + offline recognizer**: the `sherpa-onnx-vad-with-offline-asr` binary, and the Swift [generate-subtitles.swift](https://github.com/k2-fsa/sherpa-onnx/blob/master/swift-api-examples/generate-subtitles.swift) example. Maintainer on Whisper ([#931](https://github.com/k2-fsa/sherpa-onnx/issues/931)): "To support longer audios, we have to break then into chunks ... We provide VAD + ASR." So a 1-hour meeting means VAD segmentation in our glue, and timestamps get re-offset per segment. A third-party report I saw only as a search summary and did not open says whole-take Parakeet decodes fail or run out of memory at around 7–10 minutes ([EnviousWispr-Android #379](https://github.com/Envious-Labs-LLC/EnviousWispr-Android/issues/379)).

## Swift integration

- **Official `Package.swift` since 2026-07-29** ("Support swift package manager (SPM) (#3816)", from the [commit history](https://api.github.com/repos/k2-fsa/sherpa-onnx/commits?path=Package.swift)). Products: `sherpa-onnx` (static xcframework, default) and `sherpa-onnx-shared`. Binary targets are downloaded from the `xcframework` release tag, for example `sherpa-onnx-v1.13.8-macos-static.xcframework.zip`. The Swift wrapper is one 2,400-line file. `platforms: [.iOS(.v15), .macOS(.v10_15)]`. Links `c++`.
- No `unsafeFlags`, so it can be a versioned dependency.
- Acceleration: `provider: "cpu"` by default; `"coreml"` maps to ONNX Runtime's CoreML execution provider ([session.cc](https://github.com/k2-fsa/sherpa-onnx/blob/master/sherpa-onnx/csrc/session.cc): `OrtSessionOptionsAppendExecutionProvider_CoreML(sess_opts, coreml_flags)` with `coreml_flags = 0`). A community comment in [#2282](https://github.com/k2-fsa/sherpa-onnx/issues/2282) says ONNX Runtime's CoreML provider on Mac gives results "similar to CPU ... MPS and ANE can't be used" (my translation; anecdotal, not benchmarked by me). **Treat sherpa-onnx on Mac as effectively CPU-bound.**
- Memory: [#2626](https://github.com/k2-fsa/sherpa-onnx/issues/2626) reports about 1.23 GB RAM for parakeet-tdt-0.6b-v3-int8 on iOS.
- Model files: the app passes encoder/decoder/joiner/tokens paths. Archives come from the `asr-models` GitHub release tag or HF mirrors. Full download control, no built-in downloader in the Swift API.
- Hardened runtime: ONNX Runtime is a plain native library with no JIT. No special entitlement expected (not verified).

## Performance

Docs list RTF 0.325 for v3-int8 "on test audio" (machine not stated) and RK3588 ARM numbers for v2. Third-party CPU numbers on Apple Silicon (about 35× real time) are not verified. No energy data. Expect CPU-class speed, far below the Core ML/ANE and Metal options.

## Assessment

The most mature and broad of the "other" options, with the cleanest packaging (official SPM). But for our use (Parakeet on Mac) it is CPU-bound, needs VAD chunking for long files, keeps confidence behind the C struct, and only fixed v3 frontend parity yesterday. Better as a fallback or as a model-zoo than as the primary engine.
