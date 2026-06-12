---
status: in_review
---

# Phase 2: CLI + Validation Harness + Integration Test + Docs

## Overview

Build the `localllm` CLI with `download` and `run` subcommands (stdout = model message only,
stderr = diagnostics + speed summary), create the validation prompt files and sample transcript
fixture, write the env-gated model-backed integration test, and add `README.md` + `VALIDATION.md`
skeleton. This phase turns the Phase 1 library into a usable experiment harness.

Streaming (`--stream` / `generateStreaming`) is Phase 3 -- not implemented here.

## Steps

1. **Create `Sources/CLI/DownloadCommand.swift`** -- `localllm download` subcommand with `--url`
   (default Gemma URL) and `--dest` (default `~/Library/Caches/net.scosman.biscotti.localllm/`).
   Live progress line on stderr. Prints final model path to stdout on success.

2. **Create `Sources/CLI/RunCommand.swift`** -- `localllm run` subcommand with:
   - Input: `--prompt` | `--prompt-file`, optional `--transcript-file` (substituted into
     `{{transcript}}` placeholder), optional `--system` | `--system-file`.
   - Model: `--model <path>` (required; error with hint to run `download` if missing).
   - Sampling overrides: `--temp`, `--top-k`, `--top-p`, `--min-p`, `--max-tokens`, `--seed`,
     `--ctx-size`, `--repeat-penalty`.
   - Flags: `--raw` (skip template), `--thinking off|auto`, `--template builtin|gemma`.
   - Output: message to stdout; speed summary to stderr.
   - Error handling: missing files, placeholder/transcript-file mismatch, model errors.

3. **Update `Sources/CLI/LocalLLMCLI.swift`** -- register `DownloadCommand` and `RunCommand` as
   subcommands; set `run` as the default.

4. **Create `Prompts/summarize.txt`** -- instruction template with `{{transcript}}` placeholder
   for meeting summary generation.

5. **Create `Prompts/action_items.txt`** -- instruction template with `{{transcript}}` placeholder
   for action item extraction.

6. **Create `Prompts/infer_speaker_names.txt`** -- instruction template with `{{transcript}}`
   placeholder for speaker name inference from in-transcript cues.

7. **Create `Fixtures/sample_transcript.txt`** -- one synthetic diarized meeting transcript
   (Speaker A/B/C) with natural name cues ("Thanks, Mike", "Over to you, Sarah") for speaker-name
   inference. Sized well under 32k tokens.

8. **Write env-gated integration test** (`Tests/LocalLLMTests/IntegrationTests.swift`) -- gated
   on `LLM_RUN_AI=1`. Loads the model, runs a real `generate`, asserts non-empty text, sane
   token counts/stats, `finishReason` in `{endOfTurn, eos}`, fixed seed + `temp 0` determinism.
   Skipped by default (no model present).

9. **Write CLI unit tests** (`Tests/LocalLLMTests/CLITests.swift`) -- test transcript placeholder
   substitution logic and prompt/system input validation (pure helpers extracted from RunCommand).

10. **Create `README.md`** -- build/download/run instructions for the experiment.

11. **Create `VALIDATION.md`** -- manual run script (download, run each prompt, eyeball) + empty
    results section for Phase 4 findings.

## Tests

- **IntegrationTests**: env-gated (`LLM_RUN_AI=1`), loads model, generates with temp 0 + fixed
  seed, asserts non-empty text, counts > 0, sane tokensPerSecond, finishReason in {endOfTurn, eos},
  determinism across two runs with same seed. Skipped by default.
- **CLITests**: `{{transcript}}` substitution works; error on placeholder without transcript-file;
  error on transcript-file without placeholder; prompt file reading logic.
