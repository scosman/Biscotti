# Local LLM Experiment

Validates local LLM inference for Biscotti using Swift + [llama.swift](https://github.com/mattt/llama.swift) (llama.cpp) + Gemma 4 12B QAT on Apple Silicon.

**Status:** Library core + CLI complete. Waiting for Phase 4 live validation on real hardware.

## Requirements

- macOS 15+, Apple Silicon
- Swift 6.0+ toolchain (Xcode 26+)
- ~8 GB free disk space for the model

## Build

```bash
cd experiments/llm
swift build
```

The first build downloads the LlamaSwift XCFramework (~150 MB). Subsequent builds are fast.

## Download the model

```bash
swift run localllm download
```

Downloads Gemma 4 12B QAT GGUF (~8 GB) to `~/Library/Application Support/Biscotti/llms/`. Skips if already present.

Options:
- `--url <url>` -- override the model URL
- `--dest <path>` -- override the cache directory

## Run inference

```bash
# Simplest form — uses the default downloaded model
swift run localllm run --prompt "What is the capital of France?"

# Explicit model path (overrides the default)
swift run localllm run --model ~/Library/Application\ Support/Biscotti/llms/gemma-4-12b-it-UD-Q4_K_XL.gguf \
  --prompt "What is the capital of France?"

# Prompt from file with transcript substitution
swift run localllm run --prompt-file Prompts/summarize.txt \
  --transcript-file Fixtures/sample_transcript.txt
```

The model's response prints to **stdout** (clean, pipeable). Diagnostics and the speed summary print to **stderr**.

### Options

| Flag | Description |
|---|---|
| `--model <path>` | Path to a GGUF model file (defaults to the download location; errors with a hint to run `localllm download` if absent) |
| `--prompt <text>` | Inline prompt text |
| `--prompt-file <path>` | Read the prompt from a file |
| `--transcript-file <path>` | Substitute `{{transcript}}` in the prompt |
| `--system <text>` | System instruction (inline) |
| `--system-file <path>` | System instruction from a file |
| `--temp <float>` | Temperature (0 = greedy) |
| `--top-k <int>` | Top-K sampling cutoff |
| `--top-p <float>` | Nucleus sampling threshold |
| `--min-p <float>` | Min-P sampling threshold |
| `--max-tokens <int>` | Maximum tokens to generate |
| `--seed <uint64>` | RNG seed for reproducibility |
| `--ctx-size <int>` | Context window size |
| `--repeat-penalty <float>` | Repetition penalty (1.0 = disabled) |
| `--raw` | Skip chat template; send prompt verbatim |
| `--thinking off\|auto` | Thinking mode (default: off) |
| `--template builtin\|gemma` | Template implementation (default: gemma). `builtin` uses llama.cpp's heuristic (broken for Gemma 4; kept for A/B comparison) |

## Run tests

```bash
# Always-on unit tests (fast, no model needed)
swift test

# Model-backed integration tests (requires downloaded model)
LLM_RUN_AI=1 swift test
```

## Validation prompts

Three prompt templates in `Prompts/` exercise the model on a synthetic meeting transcript (`Fixtures/sample_transcript.txt`):

- `summarize.txt` -- generate a meeting summary
- `action_items.txt` -- extract action items with owners
- `infer_speaker_names.txt` -- infer real names from in-transcript cues

Run each with:
```bash
swift run localllm run --prompt-file Prompts/summarize.txt --transcript-file Fixtures/sample_transcript.txt
```

See `VALIDATION.md` for the full manual run script and findings.

## Chat template rendering -- why hand-rolled (not Jinja)

### The goal

Ideally we'd render the model's OWN embedded Jinja chat template (extractable via `llama_model_chat_template`) so we never hand-maintain per-model turn markers, thinking directives, or structural quirks. Why don't we?

### Why the C API can't do it

`llama_chat_apply_template` is **not** a Jinja engine. It pattern-matches ~50 known template families by their marker strings (see the [llama.cpp wiki: Templates supported by llama_chat_apply_template](https://github.com/ggml-org/llama.cpp/wiki/Templates-supported-by-llama_chat_apply_template)). Gemma 4 is not in its supported list -- it only recognizes old Gemma (`<start_of_turn>`), so it degenerates: drops the system message, omits `<|turn>`/`<turn|>` markers, and never injects `<|think|>`. The result is a near-bare prompt that produces garbled output.

llama.cpp's real Jinja engine (`minja`) lives in the `common/` server layer and is activated via `--jinja` in the server/CLI. It is NOT exposed through the core C API (`llama.h` / `ggml.h`). [mattt/llama.swift](https://github.com/mattt/llama.swift) re-exports only the core C API, so Jinja rendering is unavailable through our binding.

References:
- [llama.cpp Gemma 4 template PR #21326](https://github.com/ggml-org/llama.cpp/pull/21326)
- [llama.cpp Gemma 4 template discussion #21557](https://github.com/ggml-org/llama.cpp/discussions/21557)

### The right way (for the future): `swift-jinja`

[huggingface/swift-jinja](https://github.com/huggingface/swift-jinja) is the Hugging Face Jinja engine used internally by [swift-transformers](https://github.com/huggingface/swift-transformers). It can render the GGUF's embedded template directly -- it supports Gemma 4's template features (macros, `namespace`, `dictsort`, filters, loops, `enable_thinking`) and notably has a [Gemma 4 integration test contributed by mattt](https://github.com/huggingface/swift-jinja/releases/tag/v2.3.6) (the author of the `llama.swift` binding we already use).

- Swift 6, macOS 13+, Apache 2.0
- Only transitive dependency: Apple's `OrderedCollections`
- Usage: `Template(templateString).render(["messages": messages, "bos_token": "<bos>", "add_generation_prompt": true, "enable_thinking": true, ...])`, then strip the leading `<bos>` (the tokenizer adds it via `add_special`)
- ~1 day of integration work

### Decision (2026-06-12)

**Hand-roll for now.** This experiment targets a single model (Gemma 4 12B QAT) and is not a general-purpose library. The hand-rolled `GemmaChatTemplate` byte-matches the model's embedded Jinja template (cross-checked via `--show-raw`) and is locked by golden unit tests.

Revisit `swift-jinja` if/when multi-model support is needed (Project 10 or beyond). Per-model hand-rolling doesn't scale across model families with different thinking mechanisms, turn markers, and structural quirks -- `swift-jinja` is the recommended path then.

### Sources

- [llama.cpp wiki: Templates supported by llama_chat_apply_template](https://github.com/ggml-org/llama.cpp/wiki/Templates-supported-by-llama_chat_apply_template)
- [llama.cpp Gemma 4 template PR #21326](https://github.com/ggml-org/llama.cpp/pull/21326)
- [llama.cpp Gemma 4 template discussion #21557](https://github.com/ggml-org/llama.cpp/discussions/21557)
- [huggingface/swift-jinja](https://github.com/huggingface/swift-jinja) (v2.3.6+, Gemma 4 test)
- [huggingface/swift-transformers](https://github.com/huggingface/swift-transformers)
- [ai.google.dev Gemma formatting](https://ai.google.dev/gemma/docs/formatting) + [thinking docs](https://ai.google.dev/gemma/docs/thinking)
