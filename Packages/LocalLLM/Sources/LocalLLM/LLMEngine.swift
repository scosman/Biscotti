import Foundation
import LlamaSwift

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

/// A single-model LLM engine backed by llama.cpp.
///
/// Loads a GGUF model once and serves many independent single-turn generations.
/// Each `generate` call uses a fresh KV cache (no state carry-over between calls).
/// Thread-safe via Swift actor isolation.
public actor LLMEngine { // swiftlint:disable:this type_body_length
    // nonisolated(unsafe) so deinit can free the C handles. These are only mutated
    // within the actor's isolation domain (init, generate, unload, deinit).
    private nonisolated(unsafe) var model: OpaquePointer?
    private nonisolated(unsafe) var context: OpaquePointer?
    private nonisolated(unsafe) var vocab: OpaquePointer?
    private let config: EngineConfig
    private var loadDuration: TimeInterval?
    private var isFirstGenerate = true

    /// Load a model and create a context.
    ///
    /// - Parameters:
    ///   - modelPath: Path to a GGUF model file.
    ///   - config: Engine configuration (context size, GPU layers, etc.).
    /// - Throws: `LocalLLMError.modelFileNotFound`, `.modelLoadFailed`, `.contextCreationFailed`.
    public init(modelPath: URL, config: EngineConfig = .default) async throws {
        _ = backendInitOnce
        self.config = config

        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw LocalLLMError.modelFileNotFound(modelPath)
        }

        let loadStart = ContinuousClock.now

        // Load model
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = Int32(config.nGpuLayers)

        guard let loadedModel = llama_model_load_from_file(modelPath.path, modelParams) else {
            throw LocalLLMError.modelLoadFailed(
                "llama_model_load_from_file returned null for \(modelPath.path)"
            )
        }
        model = loadedModel

        // Create context
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(config.contextSize)
        if let threadCount = config.threadCount {
            ctxParams.n_threads = Int32(threadCount)
            ctxParams.n_threads_batch = Int32(threadCount)
        }

        guard let ctx = llama_init_from_model(loadedModel, ctxParams) else {
            llama_model_free(loadedModel)
            model = nil
            throw LocalLLMError.contextCreationFailed(
                "llama_init_from_model returned null (contextSize=\(config.contextSize))"
            )
        }
        context = ctx
        vocab = llama_model_get_vocab(loadedModel)

        let loadEnd = ContinuousClock.now
        loadDuration = Self.durationSeconds(from: loadStart, to: loadEnd)
    }

    /// Run a single-turn generation (non-streaming).
    ///
    /// Internally buffers over the same decode loop as `generateStreaming`, so both paths
    /// produce identical `GenerationResult`s.
    ///
    /// - Parameters:
    ///   - prompt: The user's message.
    ///   - system: Optional system instruction.
    ///   - options: Generation parameters (sampling, limits, thinking mode).
    /// - Returns: The model's response with timing stats.
    /// - Throws: `LocalLLMError` on failure.
    public func generate(
        prompt: String,
        system: String? = nil,
        options: GenerationOptions = .default
    ) async throws -> GenerationResult {
        // Buffered: ignore per-token callbacks, just return the final result.
        try await runGeneration(prompt: prompt, system: system, options: options, onToken: nil)
    }

    /// Run a single-turn generation with streaming.
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
    ///   - prompt: The user's message.
    ///   - system: Optional system instruction.
    ///   - options: Generation parameters (sampling, limits, thinking mode).
    /// - Returns: A stream of `StreamEvent`s.
    public func generateStreaming(
        prompt: String,
        system: String? = nil,
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
                        prompt: prompt, system: system, options: options
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
        prompt: String,
        system: String?,
        options: GenerationOptions,
        onToken: (@Sendable (String) -> Void)?
    ) async throws -> GenerationResult {
        guard let ctx = context, let vocab else {
            throw LocalLLMError.generationFailed("Engine not loaded or already unloaded")
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
                system: system, user: prompt, addGenerationPrompt: true
            )
        } else {
            promptString = prompt
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

        // 3. Prompt eval
        let evalStart = ContinuousClock.now
        try promptEval(tokens: tokens, ctx: ctx)
        let evalEnd = ContinuousClock.now

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
}
