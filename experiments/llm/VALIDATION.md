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

> The integration tests default to the model at `~/Library/Application Support/Biscotti/llms/gemma-4-12b-it-UD-Q4_K_XL.gguf` (matching `localllm download`'s default). If you used `--dest` to download elsewhere, set `LLM_MODEL_PATH=/path/to/model.gguf` alongside `LLM_RUN_AI=1`.

### 3. Run each validation prompt

```bash
MODEL=~/Library/Application\ Support/Biscotti/llms/gemma-4-12b-it-UD-Q4_K_XL.gguf

# Summarize
swift run localllm run --model $MODEL --prompt-file Prompts/summarize.txt --transcript-file Fixtures/sample_transcript.txt --seed 42 --temp 0

# Action items
swift run localllm run --model $MODEL --prompt-file Prompts/action_items.txt --transcript-file Fixtures/sample_transcript.txt --seed 42 --temp 0

# Speaker name inference
swift run localllm run --model $MODEL --prompt-file Prompts/infer_speaker_names.txt --transcript-file Fixtures/sample_transcript.txt --seed 42 --temp 0
```

### 4. A/B template comparison

```bash
# Hand-rolled Gemma 4 template (default — uses <|turn>/<turn|> markers)
swift run localllm run --model $MODEL --prompt "Summarize in one sentence: the quick brown fox jumps over the lazy dog." --template gemma --seed 42 --temp 0

# Built-in template (llama.cpp heuristic — broken for Gemma 4, kept for A/B comparison)
swift run localllm run --model $MODEL --prompt "Summarize in one sentence: the quick brown fox jumps over the lazy dog." --template builtin --seed 42 --temp 0

# Use --show-raw to inspect what each template sends to the model:
swift run localllm run --model $MODEL --prompt "Summarize in one sentence: the quick brown fox jumps over the lazy dog." --template gemma --seed 42 --temp 0 --show-raw
```

### 5. Thinking mode test

```bash
swift run localllm run --model $MODEL --prompt "What is 15 * 23? Show your work." --thinking auto --seed 42 --temp 0
```

### 6. Streaming channel-awareness test

```bash
# Streaming with thinking auto — the full structured block goes to stdout:
#   === thinking === / reasoning / === response === / final answer.
# stderr carries only diagnostics (Loading model..., Generating...) + speed summary
# (and backend logs if --verbose is passed; suppressed by default).
# Redirect stderr to /dev/null to see the clean stdout block:
swift run localllm run --model $MODEL --prompt "What is 15 * 23? Show your work." --thinking auto --stream --seed 42 --temp 0 2>/dev/null > /tmp/stream_out.txt
cat /tmp/stream_out.txt  # should contain the full structured block: headers + thinking + response

# Streaming with thinking off — headers still appear on stdout; thinking section shows [none].
swift run localllm run --model $MODEL --prompt "What is 15 * 23? Show your work." --thinking off --stream --seed 42 --temp 0 2>/dev/null
# Expected stdout: "=== thinking ===" then "[none]" then "=== response ===" then the final answer.
# Expected stderr (without 2>/dev/null): diagnostics + speed summary only.
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

**Status:** Fix confirmed on hardware — no crash on exit with the ordered teardown
+ `_exit` fallback. The process exits cleanly.

---

## Results

**Setup:** Apple-silicon Mac, macOS 15; Gemma 4 12B QAT (`gemma-4-12b-it-UD-Q4_K_XL.gguf`);
llama.cpp b9601 via mattt/llama.swift.

### Stack

- [x] Model download succeeded
- [x] Model load succeeded
- [x] Integration tests passed (`LLM_RUN_AI=1 swift test`) — all gated tests run (model load,
  greedy determinism, builtin-template sanity, streaming-vs-buffered parity)
- [x] CLI runs end-to-end: download, run (streaming and non-streaming), thinking on/off, `--show-raw`
- [x] Speed (summarize prompt, 1245-token prompt, default sampling, `--thinking off`):
  - prompt eval: 1245 tok in 3.72s (334.9 tok/s)
  - generation: 204 tok in 8.61s (23.7 tok/s)
  - total: 12.39s
- [x] Load time: 2.47s
- [ ] Peak memory: not formally measured (Activity Monitor step skipped); recommend profiling on
  8 GB Macs before productionizing

### Template decision

- [x] Built-in template works correctly: **NO** — `llama_chat_apply_template`'s heuristic (b9601) is
  broken for Gemma 4. It renders a near-bare prompt with no turn markers, drops the system message,
  and never emits `<|think|>`. Diagnosed via `--show-raw` inspecting the rendered prompt.
- [x] Hand-rolled Gemma template works correctly: **YES** — `GemmaChatTemplate` with Gemma 4's
  `<|turn>`/`<turn|>` turn markers (not Gemma 3's `<start_of_turn>`/`<end_of_turn>`) now
  **byte-matches** the model's embedded Jinja template (cross-checked via `--show-raw`).
  Key details: `<|think|>\n` (newline after directive), content trimmed (matching Jinja `| trim`),
  thinking-off mode prefills an empty thought block (`<|channel>thought\n<channel|>`) to
  deterministically suppress reasoning.
- [x] Chosen default: **gemma** (hand-rolled `GemmaChatTemplate`)
- [x] Notes: The GGUF-embedded Jinja template is extractable via `llama_model_chat_template` and
  contains the correct Gemma 4 format, but `llama_chat_apply_template`'s C-side heuristic does
  not apply it correctly. A Jinja engine (`swift-jinja`) could render it directly — see
  `experiments/llm/README.md` "Chat template rendering" for the research and decision. The
  `--template builtin` flag is kept for A/B comparison. The `--show-raw` flag prints the rendered
  prompt, raw model output, and embedded chat template for template debugging.

### Sampler decision

- [x] Built-in sampler chain works correctly: **YES** — greedy determinism test passes on hardware;
  hand-rolled fallback not needed.
- [x] Notes: The `llama_sampler` chain (penalties -> top_k -> top_p -> min_p -> temp -> dist) works
  correctly for all tested configurations. No need to use the hand-rolled fallback path.

### Phase-1 validate items

- [x] Double-BOS: only one BOS token present (`add_special = true`, no literal `<bos>` in template)
- [x] Thinking-mode tokens: confirmed markers — channel: `<|channel>thought\n` / `<channel|>`;
  thinking directive: `<|think|>` (in system turn); turn markers: `<|turn>` / `<turn|>` (Gemma 4,
  NOT Gemma 3's `<start_of_turn>` / `<end_of_turn>`)
- [x] b9601 API specifics: confirmed KV-cache-clear call (`llama_memory_clear`)

### Channel marker streaming fix

**Observation:** Gemma 4's reasoning-channel markers (`<|channel>thought\n` ...
`<channel|>`) were confirmed on real hardware during `--thinking auto` runs (validates
Phase-1 item #4 — thinking-mode tokens). In the original `--stream` mode, these markers
leaked raw into stdout because the decode loop emitted tokens live while `OutputParser`
only cleaned the buffered final text.

**Fix:** `StreamingChannelSplitter` — an incremental channel splitter wired into
`generateStreaming` — now classifies raw token pieces into `.token` (final content)
and `.reasoningToken` (thinking content) in real time. Markers that span multiple
tokens are handled via a tail buffer (withheld until a marker is matched or ruled
out). The final `.done(GenerationResult)` matches what buffered `generate()` returns
for the same input.

**CLI routing:** The full structured result — both section headers, thinking content
(or `[none]`), and the final message — all go to **stdout**. Only diagnostics
(`Loading model...`, `Generating...`) and the speed summary stay on **stderr**. This
split is intentional: the llama.cpp/ggml backend emits noisy Metal kernel-compile
logs to stderr, so filtering stderr also kills any headers routed there; keeping
the structured block on stdout keeps it visible and clean. Backend log noise is
suppressed by default (no-op callback on both `llama_log_set` and `ggml_log_set`);
pass `--verbose` to restore it for debugging.

**CLI headers (unconditional):** Both `=== thinking ===` and `=== response ===`
section headers are ALWAYS printed to stdout, regardless of `--thinking` mode or
whether any reasoning was produced. When no reasoning is present, `[none]` appears
under the thinking header. Each header is preceded by a blank line for visual
separation. This makes the thinking section always visible so the user can tell at a
glance whether the model is reasoning. In streaming mode, the thinking header prints
at generation start; `[none]` is emitted before the response header if no
`.reasoningToken` events arrived. In non-streaming mode, the pattern is:
`=== thinking ===` then reasoning or `[none]`, then `=== response ===`, then the
message — all on stdout.

**Status:** Build green + 139 always-on tests pass (including 19 splitter unit tests
covering: marker splitting across tokens, one-char-at-a-time feeding, off-mode
suppression, auto-mode routing, unclosed thinking blocks, no-leak assertions,
concatenation parity with `OutputParser.parse`, edge cases). Live streaming UX
confirmed on hardware — channels route correctly in real time.

### Prompt quality

All three tasks run against the synthetic diarized transcript fixture
(`Fixtures/sample_transcript.txt`), default sampling, `--thinking off`.

#### Summarize
- Quality: 4/5 (Good)
- Notes: Accurate multi-paragraph summary covering all key topics, decisions, and context.
  No hallucinations. Captures the meeting structure and outcomes faithfully.

#### Action items
- Quality: 5/5 (Excellent)
- Notes: Captured all action items with correct owners and deadlines. Correctly inferred
  speaker real names (Mike/Priya/Sarah) for ownership even though the prompt only labels
  Speaker A/B/C. Honest "Not specified" where no deadline was mentioned. No hallucinations
  or misses.

#### Speaker name inference
- Quality: 5/5 (Perfect)
- Notes: Speaker A=Sarah, B=Mike, C=Priya — each with accurate verbatim supporting quotes
  that appear in the transcript. No hallucinations.

### Recommendation for Project 10

Local Gemma 4 12B QAT is **viable** for Biscotti's on-device transcript processing. The
stack runs reliably on Apple silicon and produces accurate, useful output across
summarization, action-item extraction, and speaker-name inference with no observed
hallucinations, at acceptable speed (~24 tok/s generation, ~2.5s load) for
non-interactive post-meeting processing.

**Productionization notes:**

1. **Port `LocalLLM` largely as-is** — the actor engine, streaming, and channel-aware output
   parsing are production-grade. The value types, error handling, and concurrency model match
   the repo's existing patterns.
2. **Adopt `swift-jinja` for chat templating** when supporting more than one model family.
   Single pinned model is fine hand-rolled; per-model hand-rolling doesn't scale across
   model families with different thinking mechanisms. See `README.md` "Chat template rendering."
3. **Remove the CLI `_exit` Metal-teardown workaround** once upstream fixes the ggml `rsets`
   assert (tracked: ggml-org/llama.cpp `ggml-metal-device.m`). The library-side teardown
   (`unload` + `shutdown`) is correct; `_exit` is a CLI-only belt-and-suspenders.
4. **Profile peak memory on 8 GB Macs** before shipping — not measured in this validation.
   The 12B QAT model loads into unified memory; 8 GB machines may be tight.
