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

## Known issue: ggml-metal teardown crash on exit

**Symptom:** After generation completes and output prints successfully, the process
aborts at exit with:
```
GGML_ASSERT([rsets->data count] == 0) failed  (ggml-metal-device.m:622)
```
The assert fires inside `ggml_metal_rsets_free` -> `ggml_metal_device_free`, called
from a C++ static destructor during `__cxa_finalize_ranges` at `exit()`.

**Root cause:** `llama_backend_free()` was never called, so the global Metal device
(with its GPU residency sets) was left to a static destructor that expects all
residency sets to be empty — but they aren't because contexts/models weren't freed
before the device.

**Fix applied:** `LocalLLMRuntime.shutdown()` calls `llama_backend_free()` explicitly
after `engine.unload()` frees the context/model. The CLI calls this on the success
path. Additionally, `_exit(EXIT_SUCCESS)` is used as a belt-and-suspenders fallback
to bypass C++ static destructors entirely, because the QMD project (tobi/qmd#368,
tobi/qmd#674) found that some llama.cpp builds still fire the assert even with
correct teardown order.

**Upstream references:**
- ggml-org/llama.cpp `ggml/src/ggml-metal/ggml-metal-device.m` — the assert says
  "most likely you haven't deallocated all Metal resources before exiting"
- tobi/qmd#368, tobi/qmd#674 — same crash in another llama.cpp consumer; `_exit()`
  is the reliable workaround
- ggml-org/llama.cpp#17869 — unrelated (macOS backtrace printing), but referenced in
  the crash log's backtrace output

**Status:** Fix builds and passes always-on tests. Needs hardware verification to
confirm the crash is resolved.

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
