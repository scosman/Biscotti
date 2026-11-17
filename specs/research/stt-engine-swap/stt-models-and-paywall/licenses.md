# Model licenses — free, redistributed macOS app

Research date: 2026-10-21. This doc gives facts and flags. It does not make legal conclusions — the license decision is the user's to make.

## Matrix

| License | Models | Commercial / free-app use | Main obligations | Flag |
|---|---|---|---|---|
| **MIT** | Whisper large-v3-turbo, distil-large-v3.5, Moonshine (all streaming + English models), Phi-4-multimodal, VibeVoice-ASR | Yes | Keep the copyright + license notice | OK |
| **Apache-2.0** | Qwen3-ASR (+ForcedAligner), IBM Granite Speech (except `-nc`), Cohere Transcribe, Voxtral (open models), Whisper large-v3 (per HF card), MOSS-Transcribe-Diarize, ARK-ASR, Hojo, higgs-audio | Yes | Keep the license + NOTICE, state changes, patent-retaliation clause | OK. Cohere is **gated** (HF login + agree to share contact info), which complicates automatic in-app download from the original repo |
| **CC-BY-4.0** | **Parakeet TDT 0.6B v2/v3**, Canary-1b-v2/flash, Canary-Qwen-2.5B, Kyutai STT, (already used: SpeakerKit `speakerkit-coreml`) | Yes ("available for commercial use" — NVIDIA cards) | Attribution: creator ID, copyright notice, license reference, warranty-disclaimer notice, URI "where reasonably practicable"; **indicate modifications** (a Core ML conversion/quantization is a modification); no added restrictions on the material; no endorsement implied ([CC BY 4.0 legal code §3(a), §2(a)(5)(B), §2(a)(6)](https://creativecommons.org/licenses/by/4.0/legalcode.en)). "Any reasonable manner based on the medium" — e.g., an About/Acknowledgements screen | OK with attribution. Biscotti already ships a CC-BY-4.0 model (SpeakerKit), so the attribution path exists |
| **NVIDIA Open Model License** (agreement dated 2025-10-24) | parakeet-unified-en-0.6b, nemotron-speech-streaming-en-0.6b | Yes: "perpetual, worldwide, non-exclusive, no-charge, royalty-free", commercial use and derivative distribution allowed | Redistribution needs a NOTICE text: "Licensed by NVIDIA Corporation under the NVIDIA Open Model License". **Guardrail clause:** rights "automatically terminate" if you "bypass, disable, reduce the efficacy of, or circumvent any technical limitation, safety guardrail…". Patent/copyright litigation termination ([NVIDIA OML](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/), fetched via WebFetch summary) | ⚠️ Usable, but more conditions than CC-BY. Review before choosing unified-en over TDT v2 |
| **OpenMDW-1.1** | nemotron-3.5-asr-streaming-0.6b | Yes: "permission is hereby granted, free of charge, to deal in the Model Materials without restriction" | Keep a copy of the agreement + origin notices. Litigation termination ([license text](https://huggingface.co/nvidia/Cosmos-H-Surgical/blame/c954538d33a2110f92fbec025b554680d9a9a54f/LICENSE.OpenMDW-1.1)) | OK (model is not a quality candidate anyway) |
| **CC-BY-NC / CC-BY-NC-SA** | `granite-speech-5.0-470m-turboctc-nc` (CC-BY-NC-SA-4.0), soundsgoodai Zipformer-XL (CC-BY-NC-4.0) | **No** (non-commercial) | — | ❌ Exclude. Use the Apache `granite-speech-5.0-470m-turboctc` instead of the `-nc` sibling |
| **Moonshine Community License** | Legacy non-streaming non-English Moonshine models (Arabic, Japanese, Korean, Mandarin, Spanish Base, Ukrainian, Vietnamese) | Non-commercial free; commercial needs registration and ends above $1M revenue ([LICENSE](https://github.com/moonshine-ai/moonshine/blob/main/LICENSE)) | — | ❌ Avoid (not relevant for English) |
| **argmax-fmod-license** | `argmaxinc/parakeetkit-pro` (Argmax's Parakeet Core ML build) | Paid Pro SDK only | — | ❌ Paywalled. Use the NVIDIA weights through a free runtime instead |

## Notes

- A third-party conversion (for example a Core ML repack on Hugging Face) keeps the upstream license obligations and may add its own. Check the converter repo's license as well (runtime subtopics).
- CC-BY-4.0 "Share" covers distribution. Whether an app that downloads weights from a third-party host at runtime is "sharing" them is a legal question, flagged for the user and not decided here. Attribution in the app is cheap either way.
