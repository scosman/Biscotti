---
status: complete
---

# Apple On-Device LLMs

Apple has a framework for access to on-device models. With new models coming in the upcoming release.

Currently I use Gemma models in llama.cpp, but the new models look decent. If a user already has them installed, it might make sense to use them.

The project is to allow an "Apple Language Model" option alongside the 2 Gemma models.

* I should be able to set min model quality: older OSs have poor models, and maybe there are levels of size (a 1B model prob won't cut it).
* It should be able to detect if the model(s) are already installed, vs require download. And if this computer supports a local LLM or not via Apple APIs.
* Should be pretty transparent to the app code. We have an LLM XPC service; I'd like to keep that the same interface, or close, and just have this be a model selection param. Feasible? Are the APIs generally compatible?

## Research questions (to answer first)

* API structure and compatibility with what we need (our interface, and goals)
* Detecting currently available models
* Detecting model quality (OS version, size)?
* Any gotchas / limits / things I should know
* Can I trigger download if not downloaded?

## Model selection UI states (from discussion)

The model selection UI will need to handle a few states:

* Not available: `.unavailable(.deviceNotEligible / .appleIntelligenceNotEnabled / .modelNotReady)`. Each with their own strings.
* Since there's no progress to poll, poll for availability every 5s while on this screen. Seems okay? Needs nice UI:
  * `.modelNotReady` — "Not available yet, but we're watching for it. Watch progress in System Settings."
  * `.appleIntelligenceNotEnabled` — "Apple Intelligence not enabled. Enable in Settings."
  * Both with a link to Settings.
* Quality: different strings based on which model we get. E.g. "Older Apple model. Fast and already local, but mediocre summary quality." / "Apple's latest local model. Already downloaded as part of Apple Intelligence." (examples — follow existing style).
* Integration with the recommended tag: the best model is recommended if available. TBD whether we suggest it over Gemma 12B always. Older models are not recommended.

## Other requirements

* OS gate: doesn't appear on older builds, doesn't break Sequoia compatibility.
* Confirm we can link to Settings to enable Apple Intelligence and see download progress.

## Gating question

The token limit is the big one and may be a deal breaker. Understand what TN3193's
chunked map-reduce actually prescribes and what effort level it implies, before
committing to (or postponing) the project.
