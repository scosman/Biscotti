---
status: complete
---

# Functional Spec: Local LLM Experiment

## 1. Purpose & Scope

Validate local LLM inference for Biscotti — both the **tech stack** (Swift + `mattt/llama.swift` +
llama.cpp + Gemma 4 12B QAT on Apple silicon) and the **qualitative** output (are summaries /
action items / speaker-name inference good enough?).

Deliverables:

1. A **library** (`LocalLLM`) — production-grade, port-ready code that will be lifted into
   **Project 10 — Intelligence (LLM)** as the local provider. Exposes: model **download**,
   single-turn **generate**, and (final phase) **streaming**.
2. A **CLI** (`localllm`) — experiment-quality harness to drive the library from strings or files,
   printing a **speed summary** (total time + tokens/s).
3. **Tests** — thorough unit tests (always run) + an env-gated model-backed integration test, all
   inside `experiments/llm` only.
4. **Prompt files** — validation tasks (summarize, action items, speaker-name inference) over a
   shared sample transcript, plus a findings doc.

### Quality bar (split)

- **Library + its tests: "done" / production-grade.** Clean public API, typed errors, no leaked
  llama.cpp types, thorough tests. Written to port into Project 10 with minimal change.
- **CLI + prompt files + sample transcript: experiment-quality.** A validation harness that stays
  in `experiments/` long-term.

### Out of scope

- Multi-turn conversation / chat history (single turn only).
- The external (OpenAI-compatible) provider and the `Intelligence` package abstraction (Project 10).
- Wiring into the app, into repo-wide `make test` / `make ci`, or into CI.
- Vision / multimodal (`mmproj`) — text only.
- Custom-vocabulary injection (Project 8 / blocked upstream — see CLAUDE.md).

---

## 2. Tech stack & key facts

- **Binding:** `mattt/llama.swift` (`.upToNextMajor(from: "2.9601.0")`). It re-exports llama.cpp's
  C API via llama.cpp's precompiled XCFramework — **low-level only** (no high-level generate, and
  the README example does manual greedy sampling). Therefore **our library owns**: chat-template
  formatting, the decode loop, sampling, and stop handling.
- **Model:** Gemma 4 12B QAT GGUF — default URL
  `https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/gemma-4-12b-it-UD-Q4_K_XL.gguf`
  (the caller may override URL + destination).
- **Platform:** Apple silicon, macOS 15+. Offload all layers to Metal GPU (`n_gpu_layers = 99`).
- **Gemma 4 prompt format** (we apply it ourselves) — **must be the Gemma 4 template, not the
  Gemma 2/3 one.** The Gemma-2/3-era format is `<start_of_turn>user\n{content}<end_of_turn>\n
  <start_of_turn>model\n`; **the exact Gemma 4 template (tokens, roles, system handling) is to be
  verified in architecture** (Phase 0 below) against the model card / GGUF-embedded
  `tokenizer.chat_template`, which is the source of truth. The notes below describe the
  2/3-era shape as a starting point only.
  - **Never** add `<bos>` literally — llama.cpp's tokenizer adds it (`add_special = true`).
  - **No system role.** An optional system instruction is folded into the **first user turn**
    (prepended to the user content, separated by a blank line).
  - **Stop** generation on `<end_of_turn>` or EOS; strip these (and any trailing whitespace) from
    the returned text.
- **Sampling defaults** (Gemma-team recommended): `temperature 1.0`, `topK 64`, `topP 0.95`,
  `minP 0.0`, `repeatPenalty 1.0` (disabled). All overridable.

---

## 3. Library: `LocalLLM`

### 3.1 Model lifecycle

- **Load once, generate many.** A single engine instance loads the GGUF once (expensive: model
  weights + Metal context) and serves many independent `generate` calls. Concurrency-safe (an
  `actor`).
- Each `generate` call is **stateless / single-turn**: a fresh context (KV cache) per call, no
  carry-over between calls.
- Explicit teardown frees the model + context.

### 3.2 Public surface (shape — exact signatures finalized in architecture)

- **Model downloading** — `ModelDownloader` (or equivalent):
  - `download(from url: URL = <default Gemma URL>, to destination: URL, progress: (Progress) -> Void) async throws -> URL`
  - Destination path is **caller-provided** (a file path or a cache directory + derived filename).
  - **Skip-if-present:** if a non-empty file already exists at the destination, return it without
    re-downloading.
  - **Progress callback:** reports bytes-downloaded / total (total from `Content-Length` when
    available; `nil`/indeterminate otherwise).
  - **No resume, no checksum** (explicit decision). An interrupted download is discarded; the next
    call restarts from zero. (Partial files must not be left at the final path — download to a temp
    path and move on completion.)

- **Engine** — `LLMEngine` (actor):
  - `init(modelPath: URL, config: EngineConfig = .default) async throws` — loads the model + creates
    the llama context. `EngineConfig` covers context size (**default 32768**), `nGpuLayers` (default
    99), thread count, seed.
  - `generate(prompt: String, system: String? = nil, options: GenerationOptions = .default) async throws -> GenerationResult`
    — applies the Gemma template, runs the decode loop, samples, stops on `<end_of_turn>`/EOS,
    returns the clean message + stats.
  - **Final phase:** `generateStreaming(prompt:system:options:) -> AsyncThrowingStream<String, Error>`
    (or a token callback). Non-streaming is implemented as buffering over the same decode loop.
  - A **raw mode** (skip the chat template; tokenize/generate the prompt verbatim) — for debugging /
    base-prompt experiments. Exposed via a flag on `GenerationOptions` or a separate entry point.
  - `unload()` / teardown.

- **`GenerationOptions`** — `maxTokens` (default e.g. 2048, capped to remaining context),
  `temperature`, `topK`, `topP`, `minP`, `repeatPenalty`, `seed` (override engine seed),
  `stopSequences` (in addition to `<end_of_turn>`/EOS), `applyChatTemplate` (default true).

- **`GenerationResult`** — the clean return. The message is the headline; stats power the CLI speed
  readout and let Project 10 reason about cost:
  - `text: String` — the agent's message, turn-tokens stripped, trimmed. **This is "the message
    back," not a token stream.**
  - `promptTokenCount: Int`, `generatedTokenCount: Int`
  - `finishReason: .stop | .endOfTurn | .eos | .maxTokens | .stopSequence`
  - timings: `loadDuration?`, `promptEvalDuration`, `generationDuration`, `totalDuration`
  - derived: `tokensPerSecond` (generated tokens / generation duration)

### 3.3 Errors

Typed error enum (no leaked llama.cpp/C types), each with a clear message. At minimum:
`modelFileNotFound`, `downloadFailed(underlying)`, `modelLoadFailed`, `contextCreationFailed`,
`tokenizationFailed`, `generationFailed`, `contextOverflow(promptTokens, contextSize)`,
`cancelled`. `generate` validates that the prompt (after templating) fits the context and surfaces
`contextOverflow` rather than truncating silently.

### 3.4 Chat template handling

- A small, pure, **unit-testable** `GemmaPrompt` formatter builds the **Gemma 4**-templated string
  from `(system?, userPrompt)`. No model needed to test it. The exact Gemma 4 token sequence is
  pinned in architecture Phase 0 and cross-checked against the GGUF's embedded template.
- Tokenize the formatted string with `add_special = true` (BOS added once by llama.cpp; no literal
  `<bos>` in the string).
- Stop-token detection + stripping is likewise pure and unit-testable (operates on emitted token
  ids / decoded text).

---

## 4. CLI: `localllm`

Experiment-quality. Built with `swift-argument-parser`. Subcommands:

### 4.1 `localllm download`

- Downloads the model GGUF to a destination.
- Options: `--url <url>` (default Gemma URL), `--dest <path>` (file or directory; **required** or
  defaulted to a sensible experiment cache dir under the user's caches), shows a live progress line
  on stderr.
- Prints the final model path on success.

### 4.2 `localllm run`

- Runs a single-turn generation and prints the model's message to **stdout**; diagnostics + the
  speed summary go to **stderr** (so stdout is clean/pipeable — matches ArgMaxKit CLI convention).
- **Input (one of):**
  - `--prompt "<text>"` (inline string), or
  - `--prompt-file <path>` (read the prompt from a file).
  - Optional `--transcript-file <path>`: the prompt may contain a `{{transcript}}` placeholder that
    is replaced with the file's contents (how the validation prompt files compose with the shared
    sample transcript).
  - Optional `--system "<text>"` / `--system-file <path>`.
- **Model:** `--model <path>` to a GGUF. Defaults to the download location
  (`~/Library/Caches/net.scosman.biscotti.localllm/<model>.gguf`). If the file is missing, errors
  with a hint to run `download` (no implicit 8 GB download inside `run`).
- **Sampling overrides:** `--temp`, `--top-k`, `--top-p`, `--min-p`, `--max-tokens`, `--seed`,
  `--ctx-size`. `--raw` to skip the chat template.
- **Speed summary** (printed to stderr at the end), e.g.:
  ```
  --- speed ---
  prompt:    412 tokens in 0.83 s  (496 tok/s)
  generated: 187 tokens in 6.40 s  (29.2 tok/s)
  total:     7.61 s
  ```
  Headline metrics required: **total time** and **generation tokens/s**.
- (Streaming) Final phase: a `--stream` flag prints tokens as they arrive, then the speed summary.

### 4.3 CLI behavior / errors

- Missing file / unreadable model / generation failure → clear message on stderr, non-zero exit.
- `{{transcript}}` placeholder present but no `--transcript-file` (or vice-versa) → clear error.

---

## 5. Validation prompt files & sample transcript

Stored in the experiment (e.g. `Prompts/` + `Fixtures/`). Experiment-quality content.

- **`Fixtures/sample_transcript.txt`** — one synthetic, realistic diarized meeting transcript
  (Speaker A/B/C style, with natural name cues like "Hi Mike" so speaker-name inference has signal).
  Authored for the experiment; no real data.
- **Prompt templates** (each an instruction with a `{{transcript}}` placeholder):
  - `summarize.txt` — produce a concise meeting summary.
  - `action_items.txt` — extract action items (with owners where inferable).
  - `infer_speaker_names.txt` — map Speaker A/B/C to real names using in-transcript cues; explain
    the evidence; mark unknowns.
- Each is runnable as:
  `localllm run --model <gguf> --prompt-file Prompts/summarize.txt --transcript-file Fixtures/sample_transcript.txt`
- (Follow-up email is intentionally **excluded** for now.)

---

## 6. Tests

All tests live in `experiments/llm` and run via the experiment's **own `swift test`**. They are
**not** added to the repo's `make test` / `make ci` / `PACKAGES` (no project-wide integration).

### 6.1 Always-on unit tests (no model, fast)

Cover the production-grade library logic:

- **Gemma template formatting** — correct turn tokens; system folded into first user turn; no literal
  `<bos>`; raw mode bypasses templating.
- **Stop-token detection & stripping** — `<end_of_turn>` / EOS / custom stop sequences end
  generation and are removed from `text`; `finishReason` is correct.
- **`GenerationOptions` defaults & overrides** — Gemma defaults present; overrides applied;
  `maxTokens` clamps to remaining context.
- **Download logic** — destination/filename derivation; skip-if-present; partial-file-not-left-at-
  final-path; progress math. (Network mocked / a tiny local file served — **no** real 8 GB fetch.)
- **Stats math** — tokens/s and durations computed correctly from known inputs.
- **Error mapping** — failures surface the right typed `LocalLLM` error (no leaked C types).

### 6.2 Env-gated model-backed integration test (heavy, opt-in)

- Runs only when an env var is set (e.g. `LLM_RUN_AI=1`) — mirrors the repo's
  `BISCOTTI_RUN_AI_TESTS` / `test-ai` philosophy. A bare `swift test` stays fast and model-free.
- Requires the model present (downloads it / uses a cached path). Asserts the **stack works**:
  load succeeds, a real `generate` returns non-empty text, token counts > 0, stats are sane,
  `finishReason` is `endOfTurn`/`eos` for a short prompt. With a fixed seed + greedy (`temp 0`),
  asserts reasonable determinism.
- This validates the *stack*, not output quality. **Qualitative** judgment is human-driven (§7).

---

## 7. Findings / validation doc

A `VALIDATION.md` (or `NOTES.md`) in the experiment records the qualitative + stack findings — the
actual point of the experiment. Per repo convention, learnings live in the repo, not chat:

- The manual run script: download → run each prompt file → eyeball outputs.
- A place to record: did the Swift/llama.cpp/Gemma stack work? Speed (tok/s, load time, memory)?
  Were summaries / action items / speaker-name inferences good enough? Recommendation for Project 10
  (model size/quant, sampling, prompt phrasing learnings).

---

## 8. Open risks / to resolve in architecture

- **Does `mattt/llama.swift` expose llama.cpp's built-in sampler chain (`llama_sampler_*`) and/or
  `llama_chat_apply_template`, or only the lower-level logits API?** Decides whether we use the
  built-in sampler chain (preferred — exact llama.cpp behavior) or hand-roll top-k/top-p/min-p
  sampling over logits. To resolve by reading the package's actual exported headers in Phase 1.
  (Either way, the *chat template* is applied by us as a string — simpler and unit-testable — so
  `llama_chat_apply_template` is not required.)
- **Model name/URL** — confirm the exact GGUF resolves (the Unsloth guide page surfaced other
  variants; the user confirmed this exact new 12B QAT). Verified on first human/agent download.
- **Exact Gemma 4 chat template** — verify the Gemma 4 template (it may differ from 2/3: tokens,
  roles, whether a system role now exists) from the model card / GGUF metadata, and pin it in the
  `GemmaPrompt` formatter + its golden unit test. **Source of truth = the model's embedded
  `tokenizer.chat_template`.**
- **Memory/perf** — a 12B Q4 model is ~7–8 GB on disk and RAM; the heavy test + CLI need adequate
  hardware. Default-off keeps routine runs light.
