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

Downloads Gemma 4 12B QAT GGUF (~8 GB) to `~/Library/Caches/net.scosman.biscotti.localllm/`. Skips if already present.

Options:
- `--url <url>` -- override the model URL
- `--dest <path>` -- override the destination (file path or directory)

## Run inference

```bash
# Inline prompt
swift run localllm run --model ~/Library/Caches/net.scosman.biscotti.localllm/gemma-4-12b-it-UD-Q4_K_XL.gguf \
  --prompt "What is the capital of France?"

# Prompt from file with transcript substitution
swift run localllm run --model <path-to-model> \
  --prompt-file Prompts/summarize.txt \
  --transcript-file Fixtures/sample_transcript.txt
```

The model's response prints to **stdout** (clean, pipeable). Diagnostics and the speed summary print to **stderr**.

### Options

| Flag | Description |
|---|---|
| `--model <path>` | Path to a GGUF model file (required) |
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
| `--template builtin\|gemma` | Template implementation for A/B comparison |

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
swift run localllm run --model <path> --prompt-file Prompts/summarize.txt --transcript-file Fixtures/sample_transcript.txt
```

See `VALIDATION.md` for the full manual run script and findings.
