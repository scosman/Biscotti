# Validation: Local LLM Experiment

Manual run script and findings for the Gemma 4 12B QAT stack validation.

## Prerequisites

- Apple Silicon Mac with macOS 15+
- ~8 GB free RAM (the model loads entirely into unified memory)
- Model downloaded via `swift run localllm download`

## Manual run script

### 1. Download the model

```bash
cd experiments/llm
swift run localllm download
# Expected: prints the model path, ~8 GB downloaded
```

### 2. Run integration tests

```bash
LLM_RUN_AI=1 swift test
# Expected: all tests pass, including determinism check
```

> The integration tests default to the model at `~/Library/Caches/net.scosman.biscotti.localllm/gemma-4-12b-it-UD-Q4_K_XL.gguf` (matching `localllm download`'s default). If you used `--dest` to download elsewhere, set `LLM_MODEL_PATH=/path/to/model.gguf` alongside `LLM_RUN_AI=1`.

### 3. Run each validation prompt

```bash
MODEL=~/Library/Caches/net.scosman.biscotti.localllm/gemma-4-12b-it-UD-Q4_K_XL.gguf

# Summarize
swift run localllm run --model $MODEL --prompt-file Prompts/summarize.txt --transcript-file Fixtures/sample_transcript.txt --seed 42 --temp 0

# Action items
swift run localllm run --model $MODEL --prompt-file Prompts/action_items.txt --transcript-file Fixtures/sample_transcript.txt --seed 42 --temp 0

# Speaker name inference
swift run localllm run --model $MODEL --prompt-file Prompts/infer_speaker_names.txt --transcript-file Fixtures/sample_transcript.txt --seed 42 --temp 0
```

### 4. A/B template comparison

```bash
# Built-in template (default)
swift run localllm run --model $MODEL --prompt "Summarize in one sentence: the quick brown fox jumps over the lazy dog." --template builtin --seed 42 --temp 0

# Hand-rolled Gemma template
swift run localllm run --model $MODEL --prompt "Summarize in one sentence: the quick brown fox jumps over the lazy dog." --template gemma --seed 42 --temp 0
```

### 5. Thinking mode test

```bash
swift run localllm run --model $MODEL --prompt "What is 15 * 23? Show your work." --thinking auto --seed 42 --temp 0
```

---

## Results

_To be filled in during Phase 4 live validation._

### Stack

- [ ] Model download succeeded
- [ ] Model load succeeded
- [ ] Integration tests passed (`LLM_RUN_AI=1 swift test`)
- [ ] Speed (tok/s): ___
- [ ] Load time: ___
- [ ] Peak memory: ___

### Template decision

- [ ] Built-in template works correctly
- [ ] Hand-rolled Gemma template works correctly
- [ ] Chosen default: ___
- [ ] Notes: ___

### Sampler decision

- [ ] Built-in sampler chain works correctly
- [ ] Notes: ___

### Phase-1 validate items

- [ ] Double-BOS: only one BOS token present
- [ ] Thinking-mode tokens: confirmed markers
- [ ] b9601 API specifics: confirmed KV-cache-clear call

### Prompt quality

#### Summarize
- Quality (1-5): ___
- Notes: ___

#### Action items
- Quality (1-5): ___
- Notes: ___

#### Speaker name inference
- Quality (1-5): ___
- Notes: ___

### Recommendation for Project 10

_Model size/quant, sampling defaults, prompt phrasing learnings, anything to change for production._
