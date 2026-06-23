import ArgumentParser
import Foundation
import LocalLLM

/// CLI-facing thinking mode (maps to library's ThinkingMode).
enum CLIThinkingMode: String, ExpressibleByArgument, CaseIterable {
    case off
    case auto
}

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a single-turn generation and print the model's response."
    )

    // MARK: - Input options

    @Option(name: .long, help: "Inline prompt text.")
    var prompt: String?

    @Option(name: .long, help: "Read the prompt from a file.")
    var promptFile: String?

    @Option(name: .long, help: "Transcript file; its contents replace {{transcript}} in the prompt.")
    var transcriptFile: String?

    @Option(name: .long, help: "Inline system instruction.")
    var system: String?

    @Option(name: .long, help: "Read the system instruction from a file.")
    var systemFile: String?

    // MARK: - Model

    @Option(
        name: .long,
        help: "Path to a GGUF model file. Defaults to the localllm download cache. Run 'localllm download' to fetch one."
    )
    var model: String = defaultModelFilePath.path

    // MARK: - Sampling overrides

    @Option(name: .long, help: "Sampling temperature (0 = greedy).")
    var temp: Float?

    @Option(name: .long, help: "Top-K sampling cutoff.")
    var topK: Int?

    @Option(name: .long, help: "Top-P (nucleus) sampling threshold.")
    var topP: Float?

    @Option(name: .long, help: "Min-P sampling threshold.")
    var minP: Float?

    @Option(name: .long, help: "Maximum tokens to generate.")
    var maxTokens: Int?

    @Option(name: .long, help: "RNG seed for reproducibility.")
    var seed: UInt64?

    @Option(name: .long, help: "Context window size in tokens.")
    var ctxSize: Int?

    @Option(name: .long, help: "Repetition penalty multiplier (1.0 = disabled).")
    var repeatPenalty: Float?

    // MARK: - Flags

    @Flag(name: .long, help: "Skip chat template; send the prompt verbatim.")
    var raw: Bool = false

    @Option(name: .long, help: "Thinking mode: off (default) or auto.")
    var thinking: CLIThinkingMode = .off

    @Flag(name: .long, help: "Stream tokens to stdout as they are generated.")
    var stream: Bool = false

    @Flag(name: .long, help: "Show llama.cpp/ggml backend logs (Metal, context, etc.) on stderr. Default: quiet.")
    var verbose: Bool = false

    @Flag(name: .long, help: "Print the rendered prompt and raw model output after generation (debug).")
    var showRaw: Bool = false

    // MARK: - Run

    mutating func validate() throws {
        // Exactly one of --prompt or --prompt-file must be provided
        if prompt != nil, promptFile != nil {
            throw ValidationError("Provide either --prompt or --prompt-file, not both.")
        }
        if prompt == nil, promptFile == nil {
            throw ValidationError("Either --prompt or --prompt-file is required.")
        }
        // Only one of --system or --system-file
        if system != nil, systemFile != nil {
            throw ValidationError("Provide either --system or --system-file, not both.")
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    mutating func run() async throws {
        // Resolve prompt text
        var promptText: String = if let prompt {
            prompt
        } else {
            // validate() guarantees promptFile is non-nil when prompt is nil
            // swiftlint:disable:next force_unwrapping
            try readFile(path: promptFile!, label: "prompt file")
        }

        // Resolve system text
        let systemText: String? = if let system {
            system
        } else if let systemFile {
            try readFile(path: systemFile, label: "system file")
        } else {
            nil
        }

        // Handle {{transcript}} substitution
        let transcriptContent: String? = if let transcriptFile {
            try readFile(path: transcriptFile, label: "transcript file")
        } else {
            nil
        }
        promptText = try PromptUtils.substituteTranscript(
            prompt: promptText, transcript: transcriptContent
        )

        // Resolve model path
        let modelPath = (model as NSString).expandingTildeInPath
        let modelURL = URL(fileURLWithPath: modelPath)
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw ValidationError(
                "Model file not found at \(modelPath). "
                    + "Run `localllm download` first to fetch a model."
            )
        }

        // Build engine config
        var engineConfig = EngineConfig.default
        if let ctxSize {
            engineConfig.contextSize = ctxSize
        }
        if let seed {
            engineConfig.seed = seed
        }

        // Build generation options
        var options = GenerationOptions.default
        if let temp { options.temperature = temp }
        if let topK { options.topK = topK }
        if let topP { options.topP = topP }
        if let minP { options.minP = minP }
        if let maxTokens { options.maxTokens = maxTokens }
        if let seed { options.seed = seed }
        if let repeatPenalty { options.repeatPenalty = repeatPenalty }
        options.thinking = thinking == .auto ? .auto : .off

        // Set verbose mode before engine init (backend init reads this flag once).
        if verbose {
            LocalLLMRuntime.verbose.withLock { $0 = true }
        }

        // Template routing: --raw sends the prompt verbatim (applyChatTemplate=false).
        // Otherwise, build the rendered prompt here via GemmaChatTemplate so the exact
        // string is visible in --show-raw, and set applyChatTemplate=false to prevent
        // the engine from double-templating.
        let effectiveMessages: [LLMMessage]
        var effectiveOptions = options
        if raw {
            // Raw mode sends the prompt verbatim (no chat template). The old
            // API silently discarded --system in raw mode; preserve that
            // behavior to stay within Phase 1's "no behavior change" scope.
            effectiveMessages = [.user(promptText)]
            effectiveOptions.applyChatTemplate = false
        } else {
            effectiveOptions.applyChatTemplate = false
            let gemmaTemplate = GemmaChatTemplate(thinkingEnabled: options.thinking == .auto)
            var msgs: [LLMMessage] = []
            if let systemText {
                msgs.append(.system(systemText))
            }
            msgs.append(.user(promptText))
            let rendered = gemmaTemplate.render(
                messages: msgs, addGenerationPrompt: true
            )
            effectiveMessages = [.user(rendered)]
        }

        logStderr("Loading model...")

        // Run generation through LLMService.withConnection (in-process).
        try await LLMService.withConnection(
            model: modelURL,
            backend: .inProcess,
            config: engineConfig,
            verbose: verbose
        ) { conn in
            logStderr("Generating...")
            let result: GenerationResult
            if stream {
                result = try await runStreaming(
                    connection: conn, messages: effectiveMessages,
                    options: effectiveOptions
                )
            } else {
                result = try await conn.generate(
                    messages: effectiveMessages,
                    options: effectiveOptions
                )

                // Always print both section headers (unconditional) to stdout.
                // Blank line before each header so it stands out from prior stderr diagnostics.
                // Thinking section: reasoning content or [none].
                print("\n=== thinking ===")
                if let reasoning = result.reasoning {
                    print(reasoning)
                } else {
                    print("[none]")
                }

                // Response section: header + message, all on stdout.
                print("\n=== response ===")
                print(result.text)
            }

            // --show-raw: print the rendered prompt and raw model output (debug).
            if showRaw {
                print("\n=== rendered prompt ===")
                print(result.renderedPrompt)
                print("\n=== raw output ===")
                print(result.rawText)
            }

            // Print speed summary to stderr
            printSpeedSummary(result)
        }

        // Ordered teardown + _exit to avoid the ggml-metal rsets SIGABRT.
        LocalLLMRuntime.shutdown()
        fflush(stdout)
        fflush(stderr)
        // TODO: Remove once llama.cpp ships a fix for the rsets teardown assert
        // (upstream: ggml-org/llama.cpp ggml-metal-device.m ggml_metal_rsets_free).
        _exit(EXIT_SUCCESS)
    }

    // MARK: - Helpers

    /// Stream tokens to stdout as they arrive, returning the final result.
    ///
    /// **Routing:** the full structured result (headers, thinking content, response)
    /// goes to **stdout**; only diagnostics (`Loading model...`, `Generating...`,
    /// speed summary) stay on stderr. This is intentional: the llama.cpp/ggml backend
    /// emits noisy Metal kernel-compile logs to stderr, so filtering stderr also kills
    /// any headers routed there. Putting the structured block on stdout keeps it
    /// visible and clean.
    ///
    /// **Always-on headers** (unconditional, matches the non-streaming path):
    /// both `=== thinking ===` and `=== response ===` are printed for every run,
    /// regardless of `--thinking` mode or whether reasoning was produced. Each header
    /// is preceded by a blank line for visual separation.
    ///
    /// Streaming order:
    /// 1. Print a blank line + `=== thinking ===` to stdout before the event loop.
    /// 2. Stream each `.reasoningToken` to stdout (set `sawReasoning`).
    /// 3. Before the FIRST `.token`: if no reasoning was seen, print `[none]`;
    ///    else end the reasoning with a newline. Then print a blank line +
    ///    `=== response ===` (tracked by `responseHeaderPrinted`).
    ///    Stream content tokens to stdout.
    /// 4. After the loop, if `responseHeaderPrinted` is still false (reasoning-only
    ///    or empty output), print the missing `[none]`/newline + blank line +
    ///    `=== response ===` so both headers always appear.
    private func runStreaming(
        connection: LLMConnection,
        messages: [LLMMessage],
        options: GenerationOptions
    ) async throws -> GenerationResult {
        let stream = await connection.generateStreaming(
            messages: messages, options: options
        )

        var finalResult: GenerationResult?
        var sawReasoning = false
        var sawContent = false
        var responseHeaderPrinted = false

        // 1. Always print the thinking header up front to stdout.
        // Blank line before the header so it stands out from prior stderr diagnostics.
        print("\n=== thinking ===")
        fflush(stdout)

        for try await event in stream {
            switch event {
            case let .reasoningToken(piece):
                // 2. Stream reasoning to stdout.
                sawReasoning = true
                print(piece, terminator: "")
                fflush(stdout)

            case let .token(piece):
                // 3. Before the first content token, emit the response header.
                if !responseHeaderPrinted {
                    if !sawReasoning {
                        print("[none]")
                    } else {
                        print("")
                    }
                    // Blank line before the response header for visual separation.
                    print("\n=== response ===")
                    responseHeaderPrinted = true
                }
                sawContent = true
                print(piece, terminator: "")
                fflush(stdout)

            case let .done(result):
                finalResult = result
            }
        }

        // 4. Ensure both headers were emitted even if no content tokens arrived.
        if !responseHeaderPrinted {
            if !sawReasoning {
                print("[none]")
            } else {
                print("")
            }
            // Blank line before the response header for visual separation.
            print("\n=== response ===")
        }

        // Ensure stdout ends with a newline after streaming content tokens.
        // print(piece, terminator: "") doesn't add one, so we need it for the
        // final line. Only emit if we wrote content (don't add a bare newline
        // when the stream was reasoning-only or empty).
        if sawContent {
            print("")
        }

        guard let result = finalResult else {
            throw LocalLLMError.generationFailed("Stream ended without a .done event")
        }
        return result
    }

    private func printSpeedSummary(_ result: GenerationResult) {
        let promptTokS = result.promptEvalDuration > 0
            ? Double(result.promptTokenCount) / result.promptEvalDuration : 0
        let genTokS = result.tokensPerSecond

        var summary = "\n--- speed ---\n"
        summary += String(
            format: "prompt:    %d tok in %.2fs (%.1f tok/s)\n",
            result.promptTokenCount, result.promptEvalDuration, promptTokS
        )
        summary += String(
            format: "generated: %d tok in %.2fs (%.1f tok/s)\n",
            result.generatedTokenCount, result.generationDuration, genTokS
        )
        summary += String(format: "total:     %.2fs", result.totalDuration)
        if let loadDuration = result.loadDuration {
            summary += String(format: "   load: %.2fs", loadDuration)
        }
        summary += "\n"

        logStderr(summary)
    }
}
