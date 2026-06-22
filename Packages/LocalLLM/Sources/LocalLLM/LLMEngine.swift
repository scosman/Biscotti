import Foundation
import LlamaSwift
import os

/// Reference-type wrapper around `StreamingChannelSplitter` so an `@Sendable`
/// closure can capture and mutate it. The splitter runs synchronously inside
/// the actor-isolated decode loop, so there is no actual data race; this wrapper
/// exists solely to satisfy Swift's Sendable capture rules.
private final class SplitterBox: @unchecked Sendable {
    private var splitter: StreamingChannelSplitter

    init(suppressReasoning: Bool) {
        splitter = StreamingChannelSplitter(suppressReasoning: suppressReasoning)
    }

    func feed(_ token: String) -> [StreamingChannelSplitter.Piece] {
        splitter.feed(token)
    }

    func finish() -> [StreamingChannelSplitter.Piece] {
        splitter.finish()
    }
}

/// Ensure llama_backend_init is called exactly once per process.
private let backendInitOnce: Void = {
    llama_backend_init()

    // Suppress llama.cpp and ggml backend logging unless verbose mode is on.
    // Both loggers must be silenced: llama's for its own diagnostics, and ggml's
    // for Metal kernel-compile spam, buffer dumps, and other GPU noise.
    //
    // Passing NULL/nil resets to the DEFAULT logger (which prints to stderr) —
    // it does NOT suppress. We install a no-op @convention(c) callback instead.
    let isVerbose = LocalLLMRuntime.verbose.withLock { $0 }
    if !isVerbose {
        let silentLog: @convention(c) (
            ggml_log_level, UnsafePointer<CChar>?, UnsafeMutableRawPointer?
        ) -> Void = { _, _, _ in }
        llama_log_set(silentLog, nil)
        ggml_log_set(silentLog, nil)
    }
}()

// 8-bit (Q8_0) KV-cache experiment — LEFT DISABLED. KV cache stays 16-bit (F16).
// HW testing on Apple-silicon/Metal found F16 is the right default:
//  - Quantizing the V cache requires flash attention (llama.cpp constraint).
//  - Flash attention can't be enabled for this Gemma model on Metal: the FA kernel
//    at head_dim 256 needs ~36 KB threadgroup memory, over the 32 KB Apple-GPU limit
//    (asserts: length(36864) must be <= 32768).
//  - 8-bit K-only (the only Q8 variant that runs here) reduces KV memory but slows
//    generation a lot — not worth the trade.
// Flip experimentalKVCacheQ8 to true to re-test 8-bit K-only.
private let experimentalKVCacheQ8 = false

/// A single-model LLM engine backed by llama.cpp.
///
/// Loads a GGUF model once and serves many independent single-turn generations.
/// Each `generate` call uses a fresh KV cache (no state carry-over between calls).
/// Thread-safe via Swift actor isolation.
///
/// Two initialization modes:
/// - **Full** (`init(modelPath:config:)`): loads model + creates context. Ready
///   for both `countTokens` and `generate`.
/// - **Model-only** (`init(modelPath:nGpuLayers:)`): loads model without a
///   context/KV-cache. Ready for `countTokens` only; `generate` requires a
///   subsequent `createContext(config:)` call. Used by the XPC service to
///   tokenize prompts before the caller decides on a context size.
public actor LLMEngine { // swiftlint:disable:this type_body_length
    // nonisolated(unsafe) so deinit can free the C handles. These are only mutated
    // within the actor's isolation domain (init, generate, unload, deinit).
    private nonisolated(unsafe) var model: OpaquePointer?
    private nonisolated(unsafe) var context: OpaquePointer?
    private nonisolated(unsafe) var vocab: OpaquePointer?
    private var config: EngineConfig
    private var loadDuration: TimeInterval?
    private var isFirstGenerate = true
    private static let log = Logger(
        subsystem: "net.scosman.biscotti", category: "LLMEngine"
    )

    /// Load a model and create a context.
    ///
    /// - Parameters:
    ///   - modelPath: Path to a GGUF model file.
    ///   - config: Engine configuration (context size, GPU layers, etc.).
    /// - Throws: `LocalLLMError.modelFileNotFound`, `.modelLoadFailed`, `.contextCreationFailed`.
    public init(modelPath: URL, config: EngineConfig = .default) async throws {
        _ = backendInitOnce
        self.config = config

        let loadStart = ContinuousClock.now

        let loadedModel = try Self.loadModel(path: modelPath, nGpuLayers: config.nGpuLayers)
        model = loadedModel
        vocab = llama_model_get_vocab(loadedModel)

        // Create context
        do {
            context = try Self.makeContext(model: loadedModel, config: config)
        } catch {
            llama_model_free(loadedModel)
            model = nil
            vocab = nil
            throw error
        }

        let loadEnd = ContinuousClock.now
        loadDuration = Self.durationSeconds(from: loadStart, to: loadEnd)
    }

    /// Load a model **without** creating a context.
    ///
    /// The engine is usable for `countTokens` immediately. Call
    /// `createContext(config:)` before attempting `generate`.
    ///
    /// - Parameters:
    ///   - modelPath: Path to a GGUF model file.
    ///   - nGpuLayers: GPU layers for model loading (default 99 = all on Apple Silicon).
    /// - Throws: `LocalLLMError.modelFileNotFound`, `.modelLoadFailed`.
    public init(modelPath: URL, nGpuLayers: Int = 99) async throws {
        _ = backendInitOnce
        // Placeholder config; real config set by createContext.
        config = EngineConfig(contextSize: 0, nGpuLayers: nGpuLayers)

        let loadStart = ContinuousClock.now

        let loadedModel = try Self.loadModel(path: modelPath, nGpuLayers: nGpuLayers)
        model = loadedModel
        vocab = llama_model_get_vocab(loadedModel)
        context = nil

        let loadEnd = ContinuousClock.now
        loadDuration = Self.durationSeconds(from: loadStart, to: loadEnd)
    }

    /// Create (or recreate) the inference context with the given configuration.
    ///
    /// Must be called before `generate` on a model-only engine. Safe to call
    /// on a fully initialized engine to resize the context -- the old context
    /// is freed first, the model stays loaded.
    public func createContext(config newConfig: EngineConfig) throws {
        guard newConfig.contextSize > 0 else {
            throw LocalLLMError.contextCreationFailed(
                "contextSize must be > 0, got \(newConfig.contextSize)"
            )
        }
        guard let mdl = model else {
            throw LocalLLMError.generationFailed("Model not loaded")
        }
        // Free existing context if present
        if let ctx = context {
            llama_free(ctx)
            context = nil
        }
        context = try Self.makeContext(model: mdl, config: newConfig)
        // Preserve nGpuLayers from the original config (model loading
        // parameter, not context parameter). All other fields come from
        // newConfig, which the caller is expected to have populated from
        // the original config (see InProcessBackend.reconfigure).
        config = EngineConfig(
            contextSize: newConfig.contextSize,
            nGpuLayers: config.nGpuLayers,
            threadCount: newConfig.threadCount,
            seed: newConfig.seed
        )
    }

    // MARK: - Shared model/context helpers

    /// Load a GGUF model from disk. Shared by both init paths.
    private static func loadModel(path: URL, nGpuLayers: Int) throws -> OpaquePointer {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw LocalLLMError.modelFileNotFound(path)
        }
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = Int32(nGpuLayers)
        guard let loadedModel = llama_model_load_from_file(path.path, modelParams) else {
            throw LocalLLMError.modelLoadFailed(
                "llama_model_load_from_file returned null for \(path.path)"
            )
        }
        return loadedModel
    }

    /// Create a context from an already-loaded model.
    private static func makeContext(
        model: OpaquePointer, config: EngineConfig
    ) throws -> OpaquePointer {
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(config.contextSize)
        if let threadCount = config.threadCount {
            ctxParams.n_threads = Int32(threadCount)
            ctxParams.n_threads_batch = Int32(threadCount)
        }

        // 8-bit K cache toggle — see `experimentalKVCacheQ8` above for findings.
        if experimentalKVCacheQ8 {
            ctxParams.type_k = GGML_TYPE_Q8_0
        }

        guard let ctx = llama_init_from_model(model, ctxParams) else {
            throw LocalLLMError.contextCreationFailed(
                "llama_init_from_model returned null (contextSize=\(config.contextSize))"
            )
        }
        return ctx
    }

    // MARK: - Token counting

    /// Count the tokens that the model's tokenizer produces for a message list.
    ///
    /// Applies the same chat template and tokenization pipeline as `generate`,
    /// but returns only the token count -- no context, sampling, or KV-cache
    /// work. Only requires the model to be loaded (vocab); does not need a
    /// context.
    ///
    /// - Parameters:
    ///   - messages: The conversation messages.
    ///   - applyChatTemplate: Whether to render the chat template (default true).
    ///   - thinking: Thinking mode for template rendering (default .off).
    /// - Returns: The number of tokens in the rendered prompt.
    /// - Throws: `LocalLLMError.tokenizationFailed` or `.generationFailed` if
    ///   the model is not loaded.
    public func countTokens(
        messages: [LLMMessage],
        applyChatTemplate: Bool = true,
        thinking: ThinkingMode = .off
    ) throws -> Int {
        guard let vocab else {
            throw LocalLLMError.generationFailed("Engine not loaded or already unloaded")
        }

        let promptString: String
        if applyChatTemplate {
            let template = GemmaChatTemplate(thinkingEnabled: thinking == .auto)
            promptString = template.render(
                messages: messages, addGenerationPrompt: true
            )
        } else {
            // Raw mode: concatenate all message content
            promptString = messages.map(\.content).joined()
        }

        let tokens = try tokenize(text: promptString, vocab: vocab)
        return tokens.count
    }

    /// Run a generation (non-streaming).
    ///
    /// Internally buffers over the same decode loop as `generateStreaming`, so both paths
    /// produce identical `GenerationResult`s.
    ///
    /// - Parameters:
    ///   - messages: The conversation messages.
    ///   - options: Generation parameters (sampling, limits, thinking mode).
    /// - Returns: The model's response with timing stats.
    /// - Throws: `LocalLLMError` on failure.
    public func generate(
        messages: [LLMMessage],
        options: GenerationOptions = .default
    ) async throws -> GenerationResult {
        // Buffered: ignore per-token callbacks, just return the final result.
        try await runGeneration(messages: messages, options: options, onToken: nil)
    }

    /// Run a generation with streaming.
    ///
    /// Returns an `AsyncThrowingStream` that yields `.token(String)` for final content,
    /// `.reasoningToken(String)` for thinking/reasoning content (ThinkingMode.auto only),
    /// and a final `.done(GenerationResult)` when complete. Uses the same decode loop
    /// as `generate`, so the final `GenerationResult` is identical.
    ///
    /// Channel markers (`<|channel>thought\n` / `<channel|>`) are stripped from both
    /// outputs. `generatedTokenCount` in the result is the TOTAL tokens generated
    /// (reasoning is a routing of the same token stream, not a separate count).
    ///
    /// - Parameters:
    ///   - messages: The conversation messages.
    ///   - options: Generation parameters (sampling, limits, thinking mode).
    /// - Returns: A stream of `StreamEvent`s.
    public func generateStreaming(
        messages: [LLMMessage],
        options: GenerationOptions = .default
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish(
                        throwing: LocalLLMError.generationFailed(
                            "Engine was deallocated"
                        )
                    )
                    return
                }
                do {
                    // Create a channel splitter to classify raw tokens. Wrapped in
                    // a reference-type box so the @Sendable onToken closure can
                    // mutate it (the closure runs synchronously inside the actor's
                    // decode loop, so there is no actual data race).
                    let splitterBox = SplitterBox(
                        suppressReasoning: options.thinking == .off
                    )

                    let result = try await runGeneration(
                        messages: messages, options: options
                    ) { piece in
                        let classified = splitterBox.feed(piece)
                        for item in classified {
                            switch item {
                            case let .content(text):
                                continuation.yield(.token(text))
                            case let .reasoning(text):
                                continuation.yield(.reasoningToken(text))
                            }
                        }
                    }

                    // Flush any withheld buffer at stream end.
                    let remaining = splitterBox.finish()
                    for item in remaining {
                        switch item {
                        case let .content(text):
                            continuation.yield(.token(text))
                        case let .reasoning(text):
                            continuation.yield(.reasoningToken(text))
                        }
                    }

                    continuation.yield(.done(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Propagate consumer cancellation to the decode loop. When the stream
            // consumer stops iterating or its Task is cancelled, this cancels the
            // inner Task so the decode loop's Task.isCancelled check fires promptly.
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Unified decode loop

    /// The single decode loop shared by `generate` (buffered) and `generateStreaming`.
    ///
    /// - Parameter onToken: Called with each decoded token piece. `nil` for buffered mode.
    private func runGeneration( // swiftlint:disable:this cyclomatic_complexity function_body_length
        messages: [LLMMessage],
        options: GenerationOptions,
        onToken: (@Sendable (String) -> Void)?
    ) async throws -> GenerationResult {
        guard let vocab else {
            throw LocalLLMError.generationFailed("Engine not loaded or already unloaded")
        }
        guard let ctx = context else {
            throw LocalLLMError.generationFailed(
                "No context created. Call createContext(config:) or "
                    + "reconfigure(contextSize:) before generating."
            )
        }

        let totalStart = ContinuousClock.now

        // Clear KV cache for a fresh generation
        let memory = llama_get_memory(ctx)
        if let memory {
            llama_memory_clear(memory, true)
        }

        // 1. Build prompt string
        let promptString: String
        if options.applyChatTemplate {
            let template = GemmaChatTemplate(thinkingEnabled: options.thinking == .auto)
            promptString = template.render(
                messages: messages, addGenerationPrompt: true
            )
        } else {
            promptString = messages.map(\.content).joined()
        }

        // 2. Tokenize
        let tokens = try tokenize(text: promptString, vocab: vocab)
        let promptTokenCount = tokens.count

        // Check context overflow (need at least 1 token for generation)
        if promptTokenCount + 1 > config.contextSize {
            throw LocalLLMError.contextOverflow(
                promptTokens: promptTokenCount, contextSize: config.contextSize
            )
        }

        let maxTokens = options.clampedMaxTokens(
            promptTokenCount: promptTokenCount, contextSize: config.contextSize
        )

        // 3. Prompt eval (prefill)
        let evalStart = ContinuousClock.now
        try promptEval(tokens: tokens, ctx: ctx)
        let evalEnd = ContinuousClock.now
        let prefillSeconds = Self.durationSeconds(from: evalStart, to: evalEnd)
        let prefillTPS = prefillSeconds > 0
            ? Double(promptTokenCount) / prefillSeconds : 0
        Self.log.info(
            "Prefill complete: \(Self.formatMs(prefillSeconds)) ms, \(promptTokenCount) tokens (\(String(format: "%.1f", prefillTPS)) t/s)"
        )

        // 4. Build sampler
        let sampler = SamplerBuilder.buildChain(options: options, engineSeed: config.seed)
        defer { llama_sampler_free(sampler) }

        // 5. Decode loop
        let genStart = ContinuousClock.now
        var generatedCount = 0
        var decodedText = ""
        var finishReason: FinishReason = .maxTokens

        let eosToken = llama_vocab_eos(vocab)
        // Resolve turn-close token IDs. Gemma 4 uses <turn|>; <end_of_turn> is
        // the Gemma 3 fallback. Both are checked so generation stops cleanly on
        // either model family.
        let turnCloseID = tokenIDForPiece("<turn|>", vocab: vocab)
        let endOfTurnID = tokenIDForPiece("<end_of_turn>", vocab: vocab)

        for _ in 0 ..< maxTokens {
            // Check cancellation
            if Task.isCancelled {
                throw LocalLLMError.cancelled
            }

            // Sample
            let token = llama_sampler_sample(sampler, ctx, -1)
            llama_sampler_accept(sampler, token)

            // Check stop conditions
            if token == eosToken {
                finishReason = .eos
                break
            }
            if let tcID = turnCloseID, token == tcID {
                finishReason = .endOfTurn
                break
            }
            if let eotID = endOfTurnID, token == eotID {
                finishReason = .endOfTurn
                break
            }

            // Decode token to text
            let piece = tokenToPiece(token: token, vocab: vocab)
            decodedText += piece
            generatedCount += 1

            // Check custom stop sequences BEFORE emitting the token to the stream.
            // This prevents stop-sequence tokens from leaking to the streaming consumer
            // (the buffered GenerationResult.text already strips them via OutputParser).
            if let matched = OutputParser.matchesStopSequence(
                decodedText, stopSequences: options.stopSequences
            ) {
                decodedText = String(decodedText.dropLast(matched.count))
                finishReason = .stopSequence
                break
            }

            // Emit token to stream (if streaming). Called synchronously inside the
            // actor-isolated loop -- consumer back-pressure has no effect (tokens buffer
            // in the continuation). Bounded by maxTokens; consider a back-pressured
            // channel if this becomes a bottleneck.
            onToken?(piece)

            // Feed back for next iteration: decode the single new token.
            // Uses a single-element array + withUnsafeMutableBufferPointer, matching the
            // promptEval pattern, for safe pointer lifetime.
            var tokens1 = [token]
            let decodeResult = tokens1.withUnsafeMutableBufferPointer { buf in
                let batch = llama_batch_get_one(buf.baseAddress, 1)
                return llama_decode(ctx, batch)
            }
            if decodeResult != 0 {
                throw LocalLLMError.decodeFailed(code: decodeResult)
            }
        }

        let genEnd = ContinuousClock.now
        let genSeconds = Self.durationSeconds(from: genStart, to: genEnd)
        let genTPS = genSeconds > 0
            ? Double(generatedCount) / genSeconds : 0
        Self.log.info(
            "Generation complete: \(Self.formatMs(genSeconds)) ms, \(generatedCount) tokens (\(String(format: "%.1f", genTPS)) t/s)"
        )

        // 6. Post-process
        let parsed = OutputParser.parse(
            rawText: decodedText,
            stopSequences: options.stopSequences,
            stripThinking: options.thinking == .off
        )

        // If post-processing found a stop sequence we didn't catch in the loop
        if parsed.matchedStopSequence, finishReason == .maxTokens {
            finishReason = .stopSequence
        }

        // 7. Assemble result
        let totalEnd = ContinuousClock.now

        let capturedLoadDuration: TimeInterval?
        if isFirstGenerate {
            capturedLoadDuration = loadDuration
            isFirstGenerate = false
        } else {
            capturedLoadDuration = nil
        }

        return GenerationResult(
            text: parsed.text,
            reasoning: parsed.reasoning,
            promptTokenCount: promptTokenCount,
            generatedTokenCount: generatedCount,
            finishReason: finishReason,
            loadDuration: capturedLoadDuration,
            promptEvalDuration: Self.durationSeconds(from: evalStart, to: evalEnd),
            generationDuration: Self.durationSeconds(from: genStart, to: genEnd),
            totalDuration: Self.durationSeconds(from: totalStart, to: totalEnd),
            renderedPrompt: promptString,
            rawText: decodedText,
            embeddedChatTemplate: nil
        )
    }

    /// Free the model and context. Safe to call multiple times.
    public func unload() {
        if let ctx = context {
            llama_free(ctx)
            context = nil
        }
        if let mdl = model {
            llama_model_free(mdl)
            model = nil
        }
        vocab = nil
    }

    deinit {
        if let ctx = context { llama_free(ctx) }
        if let mdl = model { llama_model_free(mdl) }
    }

    // MARK: - Internal helpers

    private func tokenize(text: String, vocab: OpaquePointer) throws -> [llama_token] {
        // llama_tokenize takes a C string (const char *) and its byte length.
        // Swift Strings bridge to C strings automatically via withCString.
        let textLen = Int32(text.utf8.count)
        let nTokensEstimate = Int(textLen) + 16
        var tokens = [llama_token](repeating: 0, count: nTokensEstimate)

        let nTokens = text.withCString { cStr in
            llama_tokenize(
                vocab,
                cStr,
                textLen,
                &tokens,
                Int32(nTokensEstimate),
                true, // add_special: let llama.cpp add BOS
                true // parse_special: recognize special tokens in the text
            )
        }

        if nTokens < 0 {
            // Negative means we need more space; absolute value is the required count
            let required = Int(-nTokens)
            tokens = [llama_token](repeating: 0, count: required)
            let nTokens2 = text.withCString { cStr in
                llama_tokenize(
                    vocab, cStr, textLen, &tokens, Int32(required),
                    true, true
                )
            }
            if nTokens2 < 0 {
                throw LocalLLMError.tokenizationFailed(
                    "Buffer too small even after resize (needed \(required))"
                )
            }
            return Array(tokens.prefix(Int(nTokens2)))
        }

        return Array(tokens.prefix(Int(nTokens)))
    }

    /// Evaluate the prompt tokens in chunks of at most `n_batch`.
    ///
    /// llama.cpp asserts that a single `llama_decode` call receives no more than
    /// `n_batch` tokens. For prompts longer than that limit we split the prefill
    /// into multiple decode calls. `llama_batch_get_one` auto-assigns KV-cache
    /// positions from the context's running counter, so consecutive calls produce
    /// a contiguous sequence with no manual position bookkeeping. Only the final
    /// chunk needs logits (for sampling); earlier chunks set logits = false via
    /// the default `llama_batch_get_one` behavior (logits on last token only),
    /// which is correct because we never sample from intermediate chunks.
    private func promptEval(tokens: [llama_token], ctx: OpaquePointer) throws {
        let batchSize = Int(llama_n_batch(ctx))
        guard batchSize > 0 else {
            throw LocalLLMError.generationFailed(
                "Context batch size is \(batchSize); expected a positive value"
            )
        }
        var mutableTokens = tokens
        var offset = 0
        let total = tokens.count

        while offset < total {
            let chunkSize = min(batchSize, total - offset)
            let result = mutableTokens.withUnsafeMutableBufferPointer { buf in
                guard let base = buf.baseAddress else { return Int32(-1) }
                let batch = llama_batch_get_one(base + offset, Int32(chunkSize))
                return llama_decode(ctx, batch)
            }
            if result != 0 {
                throw LocalLLMError.decodeFailed(code: result)
            }
            offset += chunkSize
        }
    }

    // swiftlint:disable optional_data_string_conversion
    private func tokenToPiece(token: llama_token, vocab: OpaquePointer) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let len = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        if len > 0 {
            return buf.withUnsafeBufferPointer { ptr in
                String(decoding: UnsafeRawBufferPointer(
                    start: ptr.baseAddress, count: Int(len)
                ), as: UTF8.self)
            }
        }
        if len < 0 {
            let needed = Int(-len)
            buf = [CChar](repeating: 0, count: needed + 1)
            let len2 = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
            if len2 > 0 {
                return buf.withUnsafeBufferPointer { ptr in
                    String(decoding: UnsafeRawBufferPointer(
                        start: ptr.baseAddress, count: Int(len2)
                    ), as: UTF8.self)
                }
            }
        }
        return ""
    }

    // swiftlint:enable optional_data_string_conversion

    /// Try to resolve a special token string to its ID. Returns nil if not found.
    private func tokenIDForPiece(_ piece: String, vocab: OpaquePointer) -> llama_token? {
        // Tokenize the piece as a special token to find its ID
        var token: llama_token = 0
        let count = llama_tokenize(
            vocab, piece, Int32(piece.utf8.count), &token, 1,
            false, // don't add BOS
            true // parse special tokens
        )
        if count == 1 {
            return token
        }
        return nil
    }

    /// Convert a ContinuousClock duration to seconds. Single source of truth for timing math.
    private static func durationSeconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> TimeInterval {
        let duration = end - start
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Format a duration in seconds as a millisecond string (e.g. "123.4").
    private static func formatMs(_ seconds: TimeInterval) -> String {
        String(format: "%.1f", seconds * 1000)
    }
}
