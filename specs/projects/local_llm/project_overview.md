---
status: complete
---

# Local LLM Experiment

## Goal

Build a local LLM **experiment** to validate the use of local LLMs for our task — both
the **tech stack** (does the Swift + llama.cpp + Gemma path work cleanly on Apple silicon?)
and the **qualitative** results (are the outputs good enough for Biscotti's LLM features —
summaries, action items, speaker-name inference, follow-ups?).

It lives under `experiments/`, but the **core goal is great code we can port over**, so the
quality bar is split:

- The **library + its tests are production-grade / "done"** (not throwaway experiment quality) —
  they are written to be lifted into **Project 10 — Intelligence (LLM)** as the local
  `llama.cpp` / Gemma provider.
- The **CLI and example/prompt files stay experiment-quality** and remain in `experiments/`
  long-term (a harness for validation, not shipped code).

## Where it lives

- New experiment at **`experiments/llm`**.

## Tech stack

- Use the **`mattt/llama.swift`** Swift package (`https://github.com/mattt/llama.swift`) as the
  llama.cpp binding. It re-exports llama.cpp's C APIs directly via llama.cpp's precompiled
  XCFramework — so our library builds the clean, high-level API on top of those primitives.
  (Decision: use `mattt/llama.swift`, not the in-tree llama.cpp "official" Swift bindings.)
- Model: the **Gemma 4 12B QAT** GGUF —
  `https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/blob/main/gemma-4-12b-it-UD-Q4_K_XL.gguf`.
- References:
  - The Unsloth llama.cpp guide for this model —
    `https://unsloth.ai/docs/models/gemma-4/qat#llama.cpp-guide` (chat template, sampling params).
  - **Prefer the `mattt/llama.swift` docs + general llama.cpp docs.** As a *secondary* reference for
    the decode-loop pattern only: ggml-org's `examples/llama.swiftui/.../LibLlama.swift`
    (`https://github.com/ggml-org/llama.cpp/blob/master/examples/llama.swiftui/llama.cpp.swift/LibLlama.swift`).
    Note: that's a **different** binding — we use `mattt/llama.swift`, not it.

## Features

- **A library / package exposing the functions we need:**
  - **Download API** — download the Gemma 4 12B QAT model to a cache directory. The destination
    path is provided by the caller.
  - **Single-turn call API** — pass a prompt, get the **agent message back**. Clean API: a complete
    response string, **not** token streams with random delimiters. Only one turn is needed, not
    multi-turn conversation.
  - **P2: streaming** support of the response.
- **A CLI wrapper** — call the library with strings or with prompts read from files. Prints a
  **speed summary at the end**: total time and tokens/second.
- **Tests** — test the functionality.
- **Test cases ("prompt files")** — realistic prompts for the tasks we care about, e.g.:
  - Summarize a meeting transcript.
  - Generate action items from a meeting transcript.
  - …and the other LLM tasks Biscotti wants (speaker-name inference, follow-up) — see
    `app_overview.md` → "LLM Enhancements".

## Out of scope

- Wiring into the real app, the external/OpenAI-compatible provider, or the `Intelligence`
  package abstraction — those belong to Project 10. This experiment validates the local path only.
