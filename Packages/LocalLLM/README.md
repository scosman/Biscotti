# LocalLLM

On-device LLM inference for Biscotti, built on [llama.cpp](https://github.com/ggml-org/llama.cpp) via the [llama.swift](https://github.com/mattt/llama.swift) SPM wrapper.

## What it provides

- **`LLMService`** / **`LLMConnection`** -- actor-based session API with scoped (`withConnection`) and explicit (`openConnection`/`close`) lifecycle forms.
- **`LLMEngine`** -- single-model engine: load once, generate many. Supports buffered and streaming output, greedy and sampled decoding, thinking/reasoning mode, and custom stop sequences.
- **`GemmaChatTemplate`** -- Gemma 4 chat template (byte-matches the embedded Jinja).
- **`ModelDownloader`** -- resumable GGUF model download with progress callback.
- **CLI** (`localllm`) -- `download` and `run` subcommands for interactive use and scripting.

## Architecture

Currently all inference runs **in-process** via `InProcessBackend`. Phase 2 will add an NSXPC `hosted(serviceName:)` backend for out-of-process isolation and full memory reclamation.

The `ServiceBackend` protocol decouples the connection from transport details, so adding XPC changes nothing above the backend layer.

## Building and testing

```bash
# Build (from repo root)
make build            # all packages including LocalLLM

# Unit tests (no model needed, fast)
make test

# AI integration tests (requires ~8 GB Gemma 4 model on disk)
make test-ai
```

The first build downloads the LlamaSwift XCFramework (~250 MB).

## CLI quick start

```bash
# Download the default Gemma 4 12B model
swift run --package-path Packages/LocalLLM localllm download

# Run a prompt
swift run --package-path Packages/LocalLLM localllm run --prompt "What is 2+2?"

# Streaming with thinking
swift run --package-path Packages/LocalLLM localllm run \
  --prompt "Explain quicksort" --thinking auto --stream
```

Run `localllm run --help` for all options.

## Service interface (programmatic)

```swift
import LocalLLM

let summary = try await LLMService.withConnection(
    model: modelURL,
    backend: .inProcess,
    config: .default
) { connection in
    let result = try await connection.generate(
        prompt: "Summarize this meeting.",
        options: GenerationOptions(maxTokens: 512)
    )
    return result.text
}
```

Streaming is also supported:

```swift
try await LLMService.withConnection(
    model: modelURL, backend: .inProcess
) { connection in
    for try await event in connection.generateStreaming(prompt: "Tell me a story.") {
        switch event {
        case .token(let piece): print(piece, terminator: "")
        case .reasoningToken(let piece): print("[think] \(piece)", terminator: "")
        case .done(let result): print("\n--- \(result.generatedTokenCount) tokens ---")
        }
    }
}
```

## Running tests

```bash
# Always-on unit tests (fast, no model needed)
swift test --package-path Packages/LocalLLM

# Model-backed integration tests (requires downloaded model)
BISCOTTI_RUN_AI_TESTS=1 swift test --package-path Packages/LocalLLM
```

## Chat template rendering -- why hand-rolled

The hand-rolled `GemmaChatTemplate` byte-matches the model's embedded Jinja template. `llama_chat_apply_template` cannot render Gemma 4 correctly (drops system, omits turn markers, no `<|think|>`). The proper future path for multi-model support is [huggingface/swift-jinja](https://github.com/huggingface/swift-jinja). See the chat template discussion in `research/argmax/README.md` for full details.

## Build/test gotcha: orphaned processes and the `.build` lock

When running `swift build` or `swift test` through a timeout-capable harness (e.g. the
`hooks-mcp` MCP server), killing the harness process on timeout **orphans the underlying
`swift` process**. That orphan holds the `.build` directory lock, which silently blocks
all subsequent builds and tests until the orphan is killed manually:

```bash
# Symptom: builds hang indefinitely
# Recovery:
pkill -f 'swift-build-tool'
pkill -f 'swift-frontend'
```
