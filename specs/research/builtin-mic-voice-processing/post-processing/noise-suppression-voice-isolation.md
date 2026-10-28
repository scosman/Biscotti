# Noise suppression and voice isolation (reference-free)

**Question:** can a reference-free "clean up the voice" step (Apple `AUSoundIsolation`, DeepFilterNet, RNNoise, Krisp, ai-coustics, Picovoice Koala) fix Biscotti's raw mic track, and should it go in front of WhisperKit?

**Short answer:** these tools remove noise, and some remove reverb. They are **not** echo cancellers. The echo in Biscotti's mic is mostly *remote participants' speech*, and a voice-preserving model keeps speech by design. For transcripts, the evidence says that denoising before Whisper usually **hurts** WER, because modern ASR is robust to noise but not to enhancement artifacts. Use these for human-listening playback copies, or with a strict attenuation limit, not as an ASR front end. Researched 2026-10-28.

---

## 1. Why reference-free models don't solve speaker bleed

- Noise suppressors are trained to keep speech and remove everything else. Remote speech coming out of the speakers is speech.
- Krisp's own docs split these into different products. "Noise Cancellation (NC) removes background noise." A separate model, "Background Voice Cancellation (BVC) also removes other people's voices around the user" ([Krisp docs](https://sdk-docs.krisp.ai/docs/krisp-rtc-bvc-nc)).
- Krisp also says: "If your app uses acoustic echo cancellation, put the AEC block before Krisp NC on the capture path". In other words, NC is not an AEC.
- **Reconciling with Biscotti's hardware observation.** `mic_capture_level_findings.md` reports that VPIO + Mic Mode "Voice Isolation" noticeably reduced system-audio bleed, and calls Voice Isolation a "reference-free mechanism". *(Inference.)* The more likely explanation is that the reduction came mostly from VPIO's own reference-based AEC, which runs underneath every Mic Mode, with Voice Isolation adding suppression of distant, reverberant sound. A pure voice isolator on the raw mic, with no AEC, should leave much of the remote speech in place. The VPIO subtopic should confirm; it is not established here.
- Separating a target speaker from other voices *is* possible. Krisp BVC is non-personalized; Google's joint AEC/NS/separation frontends condition on a speaker embedding ([O'Malley et al., ASRU 2021](https://doi.org/10.1109/asru51503.2021.9687942)). No open, Mac-ready, personalized model was found. Biscotti already stores voiceprints, so this is a future option, not a current one.

---

## 2. Evidence: denoising before Whisper usually hurts

- **Medical ASR, 2025.** MetricGAN+ denoising before Whisper, Parakeet, Gemini Flash 2.0 and Parrotlet-a, over 9 noise conditions: "Original noisy audio achieves lower semWER than enhanced audio in all 40 tested configurations ... with degradations ranging from 1.1% to 46.6% absolute semWER increase", and "even in original conditions, denoising introduces measurable performance penalties across all models (1.32% to 3.19%)" ([arXiv 2512.17562](https://arxiv.org/abs/2512.17562), Dec 2025).
- **SAM-Audio + Whisper, 2026.** "SAM-Audio preprocessing consistently degrades ASR performance". On English, Whisper base WER went from 10.53% to 21.66% even though PSNR improved ([arXiv 2603.04710](https://arxiv.org/html/2603.04710), revised Jul 2026).
- **Why: artifacts, not residual noise.** "We experimentally identify the artifact component as the main cause of performance degradation". Simply adding back a scaled copy of the original ("observation adding") improves ASR ([Iwamoto et al., arXiv 2201.06685](https://arxiv.org/pdf/2201.06685v2.pdf)).
- **Partial enhancement can help Whisper, full enhancement doesn't.** On VoiceBank+DEMAND with FRCRN, "Whisper reaches its best WER under much weaker correction, improving from 6.44 to 5.57 at α=.25 and returning to 6.46 at full magnitude" ([arXiv 2607.11157](https://doi.org/10.48550/arxiv.2607.11157), Jul 2026).
- **Practitioner consensus is the same.** "Generally speaking, in speech recognition, de-noising rarely works" ([openai/whisper discussion #2125](https://github.com/openai/whisper/discussions/2125)). One preprocessing guide calls noise reduction "the genuinely contentious one" and says to "treat any claim that denoising helps as a hypothesis about your data, and test it" ([Multigrid](https://multigrid.ai/learn/audio-preprocessing)).
- **Contrast with AEC.** When the interferer is a *known* playback signal, reference-based AEC trained or tuned for ASR cuts WER a lot (e.g. >70% from AEC alone in [Lin et al., Interspeech 2025](https://www.isca-archive.org/interspeech_2025/lin25b_interspeech.html)). Reference-based removal and blind denoising are different problems with different ASR outcomes.

**Takeaway for Biscotti:** don't put NS or voice isolation in the transcription path by default. If one is used, cap its attenuation (DeepFilterNet `df_set_atten_lim`, AUSoundIsolation wet/dry < 100%) and A/B it on real meetings. The "observation adding" result supports partial mixing.

---

## 3. Candidates

### 3a. Apple `AUSoundIsolation` (built-in AU, `'vois'`)

- **Availability.** `kAudioUnitSubType_AUSoundIsolation = 'vois'`, `API_AVAILABLE(macos(13.0), ios(16.0))`. The header describes it as "An audio unit that can be used to isolate a specified sound type". It is listed among Apple's **effect** subtypes (alongside PeakLimiter, DynamicsProcessor).
- **Parameters** (from the iOS 18/26 SDK `AudioUnitParameters.h`):
  - `kAUSoundIsolationParam_WetDryMixPercent`: "Global, Percent, 0->100, 100".
  - `kAUSoundIsolationParam_SoundToIsolate`: "Global, Indexed".
  - Sound types: `kAUSoundIsolationSoundType_Voice` ("standard voice isolation model (default)", macOS 13) and `kAUSoundIsolationSoundType_HighQualityVoice` ("high quality voice isolation model", **macOS 15**).
  - Header mirror: [xybp888/iOS-SDKs](https://raw.githubusercontent.com/xybp888/iOS-SDKs/master/iPhoneOS26.0.sdk/System/Library/Frameworks/AudioToolbox.framework/Headers/AudioUnitParameters.h).
- **Docs and status.** Apple's doc page for it was marked **beta** when introduced ([Loopy Pro forum, Jun 2022](https://forum.loopypro.com/discussion/50800/new-audio-unit-from-apple-ausoundisolation)). Community reverse-engineering found it is a neural-network unit, the "backbone of Apple Music Sing", with hidden properties for net paths and denoise/dereverb presets ([QuietNow](https://github.com/spotlightishere/QuietNow), 2023).
- **Offline use.** Plausible but not verified. As an effect AU it can be hosted as `AVAudioUnitEffect` in an `AVAudioEngine` graph running `enableManualRenderingMode(.offline, ...)`. QuietNow exports an M4A "with the current vocal attenuation level applied". I found no Apple statement that it works in manual rendering, and no sample-rate or latency spec.
- **Quality.** Anecdotal only: podcasters and OBS users praise natural-sounding isolation ([OBS forum](https://obsproject.com/forum/threads/apple-audio-units.168775/), [Sendegate](https://sendegate.de/t/neues-plugin-von-apple-ausoundisolation/16194)). There are no ASR or WER numbers and no CPU/ANE figures.
- **Fit.** It is free, built in and has no license issue, which makes it a candidate for a *listening* copy of the mic track. It is not an echo canceller (see §1) and not recommended in front of Whisper without testing (§2).
- **Not usable:** `AUAudioMix` (macOS 26) separates speech from ambience, but its input "is 4 channels of FOA spatial audio" with capture-time metadata ([WWDC25 session 251](https://developer.apple.com/videos/play/wwdc2025/251/)). It does not apply to a mono mic track.

### 3b. DeepFilterNet (open source)

- **License.** MIT/Apache-2.0 (`libDF/Cargo.toml`).
- **What.** Full-band 48 kHz, 20 ms windows, 10 ms hop, 2-frame lookahead, **40 ms** latency. Single-threaded RTF **0.19** on an i5-8250U ([Schröter et al., Interspeech 2023 demo](https://doi.org/10.48550/arxiv.2305.08227)). A 2025 study measured DeepFilterNet3 at RTF ≈ 0.08 with 2.1M params ([SINERGI 2025](https://www.researchgate.net/publication/392780104_Performance_of_speech_enhancement_models_in_video_conferences_DeepFilterNet3_and_RNNoise)).
- **Integration.** Rust, with a C API in `libDF/src/capi.rs`: `df_create`, `df_process_frame`, `df_set_atten_lim`, `df_set_post_filter_beta`. The crate builds `cdylib`/`staticlib`, so it can be linked into an SPM C target. The CLI only accepts 48 kHz WAV.
- **Maintenance.** The latest crate version in the repo is `0.5.7-pre`. I could not fetch the release feed to date the last release.
- **Fit.** It has an attenuation limit, which is the right knob for an ASR-safe light touch. No echo removal.

### 3c. RNNoise (Xiph)

- **License.** BSD-3 (Xiph/Mozilla/Amazon copyrights). 48 kHz, frame-based C API (`rnnoise_process_frame`), models retrained on public data with dataset updates through Jan 2025 ([README](https://github.com/xiph/rnnoise)).
- **Cost.** Extremely cheap: RTF ≈ 0.001, 60K params ([SINERGI 2025](https://www.researchgate.net/publication/392780104_Performance_of_speech_enhancement_models_in_video_conferences_DeepFilterNet3_and_RNNoise)).
- **Quality.** Below DeepFilterNet. Fine for stationary noise. No echo removal.

### 3d. Commercial SDKs

| SDK | On-device macOS | What it offers | Licensing / privacy notes |
|---|---|---|---|
| **Krisp** RTC/Desktop SDK | C++ library for Windows/macOS/Linux; 8–96 kHz; 10–32 ms frames | NC (inbound/outbound) and **BVC** (removes other voices; "works best with wired USB headsets"; "might demonstrate acceptable performance when using ... Apple MacBooks"); NC "also removes room echo (reverberation)". **No AEC**: put AEC first. | "Krisp SDK is a commercial product ... commercial license"; network access "only for license verification" ([desktop SDK](https://sdk-docs.krisp.ai/docs/desktop-sdk-bvc), [licensing](https://sdk-docs.krisp.ai/docs/licensing-information), [SDK vs API](https://sdk-docs.krisp.ai/docs/sdk-or-api)) |
| **ai-coustics** | C/C++/Rust/Python SDK with macOS arm64 builds (SDK 0.25.x) | "Quail Voice Focus" (primary speaker, for STT), "Quail Multi Speaker" (preserve multiple speakers for STT), "Rook" (for listening), VAD | Self-service keys "authorize with our backend and collect telemetry"; offline license only via sales; Pro plan $135/mo for 100k min ([docs](https://docs.ai-coustics.com/tutorials/sdk-quickstart), [pricing](https://ai-coustics.com/pricing)). Online auth and telemetry conflict with Biscotti's local-only stance. |
| **Picovoice Koala** | macOS x86_64/arm64 via C and Python SDKs (Swift package is iOS) | Streaming noise suppression | AccessKey required; free plan "Strictly Non-Commercial", Koala 100 min/month; commercial from $6,000/yr ([docs](https://picovoice.ai/docs/koala/), [pricing](https://picovoice.ai/pricing/)) |

None of the commercial SDKs does reference-based AEC, and none publishes Whisper WER impact. Krisp BVC is the only one that might suppress loudspeaker voices, as "background voices". That is an inference, untested, and Krisp positions BVC for headsets.

---

## 4. Summary table

| Option | Removes speaker-bleed speech? | Safe in front of Whisper? | License / cost | Swift path |
|---|---|---|---|---|
| AUSoundIsolation | Partially at best (it's a voice isolator) | Unknown; test first | Free, built in | `AVAudioUnitEffect` in AVAudioEngine (manual render offline: plausible, unverified) |
| DeepFilterNet3 | No | Only with attenuation limit; test | MIT/Apache | Rust C API → SPM C target |
| RNNoise | No | Same caveat | BSD-3 | C → SPM C target |
| Krisp NC/BVC | NC no; BVC maybe (untested) | Unknown | Commercial | C++ SDK |
| ai-coustics Quail | Not designed for it | Vendor targets STT; no independent data | Commercial, online auth | C/Rust SDK |
| Koala | No | Unknown | Commercial (AccessKey) | C SDK |
