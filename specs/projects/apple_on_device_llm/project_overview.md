---
status: draft
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
