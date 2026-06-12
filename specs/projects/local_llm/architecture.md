---
status: complete
---

# Architecture: Local LLM Experiment

Single-doc architecture (small/medium project — no separate component designs). Deep enough that
the coding agent executes, not designs. A few items are **explicitly delegated to the coding agent
to try/validate/decide in Phase 1** (flagged `[Phase-1 validate]`); everything else is specified.

---

## 1. Layout & packaging

```
experiments/llm/
  Package.swift                       # LocalLLM lib + localllm CLI + tests (standalone SPM)
  Sources/
    LocalLLM/                         # PRODUCTION-GRADE, port-ready library
      LLMEngine.swift                 # actor: load-once, generate-many
      ModelDownloader.swift           # GGUF download (progress, skip-if-present)
      ChatTemplate.swift              # ChatTemplating protocol + BuiltinChatTemplate + GemmaChatTemplate (hand-rolled fallback)
      Sampling.swift                  # SamplerChain wrapper (built-in) + hand-rolled fallback
      GenerationOptions.swift         # sampling/limits value type
      EngineConfig.swift              # load-time config value type
      GenerationResult.swift          # result + FinishReason + stats
      OutputParser.swift              # stop-token + thinking/channel stripping (pure)
      LocalLLMError.swift             # typed errors
    localllm/                         # EXPERIMENT-QUALITY CLI
      LocalLLMCLI.swift               # @main, root command
      DownloadCommand.swift
      RunCommand.swift
  Tests/
    LocalLLMTests/                    # always-on unit tests + env-gated integration test
  Prompts/                            # validation prompt templates (experiment content)
    summarize.txt
    action_items.txt
    infer_speaker_names.txt
  Fixtures/
    sample_transcript.txt             # one synthetic diarized transcript
  VALIDATION.md                       # manual run script + findings (the experiment's payoff)
  README.md                           # how to build/download/run
```

- **`Package.swift`** — `swift-tools-version: 6.0` (LlamaSwift requires 6.0; Swift 6 strict
  concurrency on). `platforms: [.macOS(.v15)]`. Products: `.library("LocalLLM")` +
  `.executable("localllm")`. Dependencies:
  - `https://github.com/mattt/llama.swift` — `.upToNextMajor(from: "2.9601.0")`, product
    `LlamaSwift` (re-exports the full llama.cpp C API; binary XCFramework, llama.cpp build b9601).
  - `https://github.com/apple/swift-argument-parser` — `from: "1.3.0"` (CLI only).
  - Test target may declare `Fixtures`/golden files as `resources`.
- **Not wired into repo `make` / CI / `PACKAGES`.** Built & tested via the experiment's own
  `swift build` / `swift test` (matches ArgMaxKit). The XCFramework downloads on first build.

---

## 2. Data model (value types)

- **`EngineConfig`** (load-time): `contextSize: Int = 32768`, `nGpuLayers: Int = 99`,
  `threadCount: Int? = nil` (nil → llama default), `seed: UInt64 = <fixed default>`. `.default`.
- **`GenerationOptions`** (per-call): `maxTokens: Int = 2048` (clamped to remaining context),
  `temperature: Float = 1.0`, `topK: Int = 64`, `topP: Float = 0.95`, `minP: Float = 0.0`,
  `repeatPenalty: Float = 1.0`, `repeatLastN: Int = 64`, `seed: UInt64? = nil` (override engine
  seed), `stopSequences: [String] = []`, `applyChatTemplate: Bool = true` (false ⇒ `--raw`),
  `thinking: ThinkingMode = .off`. `.default`. Defaults are the Gemma-team values.
- **`ThinkingMode`**: `.off | .auto`. `.off` = ask the model not to emit reasoning and strip any
  that appears; `.auto` = leave the template default and surface reasoning separately.
- **`GenerationResult`**:
  - `text: String` — clean final message (turn/stop/thinking tokens stripped, trimmed). **The
    headline; not a token stream.**
  - `reasoning: String?` — thought/channel content if the model emitted any (nil when none / when
    `.off` fully suppressed it).
  - `promptTokenCount: Int`, `generatedTokenCount: Int`
  - `finishReason: FinishReason` = `.endOfTurn | .eos | .maxTokens | .stopSequence`
  - `loadDuration: TimeInterval?`, `promptEvalDuration: TimeInterval`,
    `generationDuration: TimeInterval`, `totalDuration: TimeInterval`
  - `var tokensPerSecond: Double` (generated / generationDuration; 0-safe)
- **`LocalLLMError`** (enum, `Error`, `LocalizedError`; no leaked C types):
  `modelFileNotFound(URL)`, `downloadFailed(url: URL, underlying: String)`,
  `modelLoadFailed(String)`, `contextCreationFailed(String)`, `tokenizationFailed(String)`,
  `contextOverflow(promptTokens: Int, contextSize: Int)`, `generationFailed(String)`,
  `decodeFailed(code: Int32)`, `cancelled`. Each maps to a clear `errorDescription`.

All value types are `Sendable`; `Codable` where it aids the CLI `--json`-style output (optional).

---

## 3. `ModelDownloader`

```
struct ModelDownloader {
  static let defaultModelURL = URL(string:
    "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/gemma-4-12b-it-UD-Q4_K_XL.gguf")!
  func download(from: URL = Self.defaultModelURL, to destination: URL,
                progress: @Sendable (_ bytes: Int64, _ total: Int64?) -> Void) async throws -> URL
}
```

- **Destination:** caller-provided. If `destination` is a directory (existing on disk, trailing
  slash, OR a non-existent path whose extension differs from the source URL's), derive the filename
  from the URL's last path component; if a file path (extension matches the source), use it as-is.
- **Skip-if-present:** if a non-empty **regular file** (not a directory) already exists at the
  resolved path, return it without downloading (log a note).
- **Mechanism:** `URLSession` bytes/download with a delegate (or `bytes(for:)`) to stream + report
  progress; `total` from `Content-Length` (nil if absent). Write to a **temp path
  (`<dest>.partial` or a tmp dir), then atomically move** to the final path on completion — a
  partial/interrupted file is never left at the final path.
- **No resume, no checksum** (explicit). Interruption ⇒ discard temp, error out; next call restarts.
- Errors → `downloadFailed`.
- **Testable without the network:** the file-targeting / skip-if-present / directory-vs-file /
  temp-then-move logic is factored into pure helpers; tests drive them with a tiny local file or a
  stubbed `URLProtocol`. **No real 8 GB fetch in unit tests.**

---

## 4. `LLMEngine` (the core)

An `actor` (matches the repo's `ArgMaxProcessor` pattern) owning the llama.cpp handles. Loads the
model once; serves many independent single-turn generations.

```
actor LLMEngine {
  init(modelPath: URL, config: EngineConfig = .default) async throws
  func generate(prompt: String, system: String? = nil,
                options: GenerationOptions = .default) async throws -> GenerationResult
  func generateStreaming(prompt: String, system: String? = nil,
                         options: GenerationOptions = .default)
       -> AsyncThrowingStream<StreamEvent, Error>      // FINAL PHASE
  func unload()
  deinit  // frees context + model + backend
}
```

Held state (C handles via `import LlamaSwift`): `OpaquePointer` for `llama_model`, the `llama_vocab`
(from `llama_model_get_vocab`), and a reusable `llama_context` sized to `contextSize`.
`StreamEvent = .token(String) | .done(GenerationResult)`.

### 4.1 Load (`init`)

1. `llama_backend_init()` once per process (guard with a global `once`).
2. `llama_model_default_params()`; set `n_gpu_layers = config.nGpuLayers`.
   `llama_model_load_from_file(path, params)` → `modelLoadFailed` on null.
3. `llama_context_default_params()`; set `n_ctx = config.contextSize`, threads, seed-related fields
   as available. `llama_init_from_model(model, params)` → `contextCreationFailed` on null.
4. Capture `vocab = llama_model_get_vocab(model)`.

### 4.2 Generate (single-turn, stateless)

Each call uses a **fresh KV cache** (clear the context's memory at the start, e.g.
`llama_memory_clear` / kv-cache clear for the reused context — `[Phase-1 validate]` the exact
b9601 call) so calls don't bleed into each other.

1. **Build the prompt string.** Via `ChatTemplating` (§5): messages = `[(system?), user]` →
   templated string ending at the assistant generation prefix. `--raw`/`applyChatTemplate=false`
   bypasses templating (use the prompt verbatim).
2. **Tokenize.** `llama_tokenize(vocab, text, …, add_special, parse_special=true)`.
   - **Double-BOS gotcha `[Phase-1 validate]`:** Gemma auto-adds `<bos>`. Choose `add_special` so
     exactly one BOS results (inspect `tokens[0]` vs `llama_vocab_bos(vocab)`); never emit two.
   - If `promptTokens + 1 > contextSize` → `contextOverflow`.
3. **Prompt eval.** Fill a `llama_batch` with the prompt tokens (last token `logits=true`),
   `llama_decode`; non-zero return → `decodeFailed`. Time this → `promptEvalDuration`.
4. **Sampler.** Build a per-call sampler from `options` (§6).
5. **Decode loop** until a stop condition:
   - `token = sampler.sample(ctx)`; accept it into the sampler.
   - **Stop checks (before emit):** `token == llama_vocab_eos(vocab)` → `.eos`;
     `token == <end_of_turn>` id → `.endOfTurn`; `generatedTokenCount == maxTokens` → `.maxTokens`.
   - Else `piece = llama_token_to_piece(...)`; append to a rolling decoded buffer; check
     `stopSequences` against the buffer → `.stopSequence` (and trim the partial match).
   - Feed the token back: single-token `llama_batch`, `llama_decode`.
   - (Streaming) emit `.token(piece)` here.
   - Time the loop → `generationDuration`.
6. **Post-process** the raw decoded text via `OutputParser` (§7): strip any trailing stop/turn
   tokens, split off a thinking/channel block into `reasoning`, trim → `text`.
7. Assemble `GenerationResult` (counts, `finishReason`, durations, `loadDuration` only on first
   generate after load).

`unload()`/`deinit` free context, model, and backend.

### 4.3 Concurrency

The actor serializes access (model/context aren't thread-safe). `llama_decode` is synchronous and
GPU/CPU-bound; for this experiment it runs inline on the actor (as `ArgMaxProcessor` does).
**Note (not Phase-1):** if cooperative-pool occupancy matters when porting to Project 10, move the
blocking loop to a dedicated executor — out of scope here. Cancellation: the loop checks
`Task.isCancelled` between tokens and throws `.cancelled`.

---

## 5. Chat templating — `ChatTemplating`

```
protocol ChatTemplating { func render(system: String?, user: String, addGenerationPrompt: Bool) -> String }
```

- **Primary — `BuiltinChatTemplate`:** uses llama.cpp's built-in template
  (`llama_model_chat_template(model, nil)` → embedded Jinja; `llama_chat_apply_template(tmpl,
  messages, count, add_assistant, buf, len)` with `llama_chat_message{role,content}`). Roles:
  `system` (optional, Gemma 4 supports it natively) + `user`. **This is the source of truth for the
  Gemma 4 format** and avoids hand-maintaining a Jinja template.
- **Fallback — `GemmaChatTemplate` (hand-rolled):** a pure string builder for the Gemma 4 format,
  used if the built-in path is unavailable/misbehaving. Exact token sequence pinned in Phase 1 from
  the model card / embedded template; a golden unit test locks it.
- **`[Phase-1 validate]` — the user-sanctioned decision:** try `BuiltinChatTemplate` first; if it
  doesn't work cleanly with b9601 + this GGUF, fall back to `GemmaChatTemplate`. Pick one as the
  default; keep the other behind a flag for A/B in the CLI/VALIDATION.
- `system` is honored as a real system message when the template supports it (Gemma 4 does); the
  hand-rolled fallback folds system into the first user turn if needed.

---

## 6. Sampling — `Sampling.swift`

- **Primary — built-in `llama_sampler` chain.** Per-call chain built from `options`, in llama.cpp's
  standard order: penalties (`llama_sampler_init_penalties` with `repeatLastN`, `repeatPenalty`) →
  `top_k` → `top_p` → `min_p` → `temp` → final `dist(seed)`; when `temperature == 0` use a single
  `greedy` sampler instead. `llama_sampler_sample(chain, ctx, -1)` per step; `llama_sampler_accept`.
  Freed after the call.
- **Fallback — hand-rolled** (if needed): read logits (`llama_get_logits_ith`), apply repeat penalty
  over the last-N window, temperature scale, top-k cut, top-p (nucleus) cut, min-p cut, softmax,
  sample with a seeded RNG; `temperature == 0` → argmax. The transform steps are **pure and
  unit-tested** with known logit vectors.
- `[Phase-1 validate]`: prefer built-in; fall back only if necessary.

---

## 7. Output parsing — `OutputParser.swift` (pure, unit-tested)

- **Stop/turn stripping:** remove a trailing `<end_of_turn>` / `<eos>` / matched stop-sequence and
  trim whitespace.
- **Thinking/channel handling `[Phase-1 validate]` for exact tokens:** Gemma 4 may emit a reasoning
  channel (e.g. `<|channel>thought … <channel|>` / `<|think|>` markers). The parser detects such a
  block, routes it to `GenerationResult.reasoning`, and returns only the final answer as `text`. For
  `ThinkingMode.off` we both (a) steer the prompt/template against reasoning where possible and
  (b) defensively strip any block that still appears. The exact marker tokens are pinned in Phase 1
  from observed output; the parser is written table-driven so updating markers is a one-line change.
- All operations are string→string and tested without the model.

---

## 8. CLI — `localllm`

`swift-argument-parser`, root `localllm` with two subcommands. **stdout = the model's message only;
stderr = diagnostics + the speed summary** (clean, pipeable — matches the ArgMaxKit CLI).

- **`localllm download`** — `--url` (default Gemma URL), `--dest <path>` (file or dir; defaults to
  `ModelDownloader.defaultModelPath` — the full `.gguf` file path under
  `~/Library/Caches/net.scosman.biscotti.localllm/`, same path `run` reads). Live progress line on
  stderr; prints the final model path on success.
- **`localllm run`** —
  - Input (exactly one of): `--prompt "<text>"` | `--prompt-file <path>`. Optional
    `--transcript-file <path>` substituted into a `{{transcript}}` placeholder in the prompt.
    Optional `--system <text>` / `--system-file <path>`.
  - `--model <path>` (optional; defaults to the download location
    `~/Library/Caches/net.scosman.biscotti.localllm/<model>.gguf`; errors w/ hint to run `download`
    if absent — never an implicit 8 GB fetch inside `run`).
  - Overrides: `--temp --top-k --top-p --min-p --max-tokens --seed --ctx-size --repeat-penalty`,
    `--raw` (skip template), `--thinking off|auto` (default off), `--template builtin|gemma`
    (selects the §5 path for A/B). `--stream` (final phase).
  - Output: message to stdout; **speed summary to stderr** at the end:
    ```
    --- speed ---
    prompt:    412 tok in 0.83s (496 tok/s)
    generated: 187 tok in 6.40s (29.2 tok/s)
    total:     7.61s   load: 1.90s
    ```
    Required headline metrics: total time + generation tok/s.
  - Errors: missing/unreadable files, placeholder/`--transcript-file` mismatch, model-load /
    generation failure → clear stderr message, non-zero exit.

---

## 9. Validation content (experiment-quality)

- **`Fixtures/sample_transcript.txt`** — one synthetic diarized transcript (Speaker A/B/C), with
  natural name cues ("Thanks, Mike", "Over to you, Sarah") so speaker-name inference has signal;
  sized well under 32k-token context. No real data.
- **`Prompts/{summarize,action_items,infer_speaker_names}.txt`** — instruction templates, each with
  a `{{transcript}}` placeholder. (No follow-up email.)
- **`VALIDATION.md`** — the manual run script (download → run each prompt → eyeball) plus a results
  section to record: did the stack work; speed (tok/s, load, memory); output quality per task;
  built-in-vs-hand-rolled template decision; recommendation for Project 10. (Per repo convention,
  learnings live here, not in chat.)

---

## 10. Testing strategy

In `experiments/llm` only; the experiment's own `swift test`. Framework: **Swift Testing**
(`@Test`/`#expect`, as LlamaSwift + this repo use), `XCTest` acceptable if simpler for a case.

**Always-on unit tests (no model):**
- `GemmaChatTemplate` golden render (system+user, user-only, addGenerationPrompt on/off); no double
  `<bos>` in the string.
- `OutputParser`: stop/turn stripping; stop-sequence trimming; thinking/channel split into
  `reasoning`; idempotence.
- `GenerationOptions`/`EngineConfig` defaults (Gemma values) + override application; `maxTokens`
  clamp logic.
- Sampling transforms (hand-rolled path): top-k/top-p/min-p/temperature/penalty over known logit
  vectors; `temp == 0` ⇒ argmax; seed determinism.
- `ModelDownloader` pure helpers: dir-vs-file dest, filename derivation, skip-if-present,
  temp-then-move, progress math (stubbed `URLProtocol`/local file — no 8 GB fetch).
- `LocalLLMError` mapping/messages.
- `tokensPerSecond` / duration math.

**Env-gated integration test (heavy, opt-in — e.g. `LLM_RUN_AI=1`):**
- Requires the model present. Asserts the **stack**: load OK; a real `generate` returns non-empty
  `text`, counts > 0, sane stats, `finishReason ∈ {endOfTurn, eos}` for a short prompt; fixed seed +
  `temp 0` ⇒ reasonable determinism; built-in template path produces a sane tokenization. Validates
  the stack, not output quality (quality is human-judged via `VALIDATION.md`).

---

## 11. Error handling & logging

- All failures surface as `LocalLLMError` with actionable messages; C null/non-zero returns mapped
  at the boundary. `generate` prefers `contextOverflow` over silent truncation.
- Library logging is minimal/opt-in (no noisy prints); diagnostics belong to the CLI (stderr). Set
  llama.cpp log level low/quiet in the library; CLI may raise verbosity with a `--verbose` flag.

---

## 12. Open items delegated to Phase 1 (`[Phase-1 validate]`, user-sanctioned)

1. **Built-in vs hand-rolled chat template** — try `llama_chat_apply_template`; fall back to
   `GemmaChatTemplate`; choose the default, keep the other for A/B.
2. **Built-in vs hand-rolled sampler** — prefer the `llama_sampler` chain; fall back if needed.
3. **Double-BOS** — set `add_special` so exactly one `<bos>` is tokenized.
4. **Thinking-mode tokens** — pin Gemma 4's reasoning-channel markers from observed output; wire the
   table-driven `OutputParser` + default `.off` behavior.
5. **b9601 API specifics** — exact KV-cache-clear call and any renamed symbols for this build.

Everything else is fully specified above.
