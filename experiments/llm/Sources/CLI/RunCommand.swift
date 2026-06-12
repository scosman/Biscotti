import ArgumentParser
import Foundation
import LocalLLM

/// Which chat template implementation to use (for A/B comparison in Phase 4).
enum TemplateChoice: String, ExpressibleByArgument, CaseIterable, Sendable {
    case builtin
    case gemma
}

/// CLI-facing thinking mode (maps to library's ThinkingMode).
enum CLIThinkingMode: String, ExpressibleByArgument, CaseIterable, Sendable {
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
    var model: String = ModelDownloader.defaultModelPath.path

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

    @Option(name: .long, help: "Template implementation: builtin (default) or gemma.")
    var template: TemplateChoice = .builtin

    @Flag(name: .long, help: "Stream tokens to stdout as they are generated.")
    var stream: Bool = false

    @Flag(name: .long, help: "Show llama.cpp/ggml backend logs (Metal, context, etc.) on stderr. Default: quiet.")
    var verbose: Bool = false

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

    mutating func run() async throws {
        // Resolve prompt text
        var promptText: String
        if let prompt {
            promptText = prompt
        } else {
            promptText = try readFile(path: promptFile!, label: "prompt file")
        }

        // Resolve system text
        let systemText: String?
        if let system {
            systemText = system
        } else if let systemFile {
            systemText = try readFile(path: systemFile, label: "system file")
        } else {
            systemText = nil
        }

        // Handle {{transcript}} substitution
        let transcriptContent: String?
        if let transcriptFile {
            transcriptContent = try readFile(path: transcriptFile, label: "transcript file")
        } else {
            transcriptContent = nil
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
        options.applyChatTemplate = !raw
        options.thinking = thinking == .auto ? .auto : .off

        // Set verbose mode before engine init (backend init reads this flag once).
        if verbose {
            LocalLLMRuntime.verbose.withLock { $0 = true }
        }

        // Load engine
        logStderr("Loading model...")
        let engine = try await LLMEngine(modelPath: modelURL, config: engineConfig)

        // Override the template choice if needed.
        // The --template flag selects builtin vs gemma for A/B comparison (Phase 4).
        // --raw takes precedence: skip ALL templating regardless of --template.
        let useGemmaTemplate = template == .gemma && !raw

        // Resolve effective prompt/system/options for the template choice
        let effectivePrompt: String
        let effectiveSystem: String?
        var effectiveOptions = options
        if useGemmaTemplate {
            // Use the hand-rolled Gemma template: pass raw mode to the engine and
            // build the prompt ourselves using GemmaChatTemplate.
            effectiveOptions.applyChatTemplate = false
            let gemmaTemplate = GemmaChatTemplate(thinkingEnabled: options.thinking == .auto)
            effectivePrompt = gemmaTemplate.render(
                system: systemText, user: promptText, addGenerationPrompt: true
            )
            effectiveSystem = nil
        } else {
            effectivePrompt = promptText
            effectiveSystem = systemText
        }

        // Generate (streaming or buffered). Wrapped in do/catch so that teardown
        // (unload + backend shutdown) runs on BOTH success and error paths. Without
        // this, a mid-generation error (decodeFailed, cancelled, etc.) would skip
        // backend teardown and hit the same ggml-metal rsets assert on exit.
        do {
            logStderr("Generating...")
            let result: GenerationResult
            if stream {
                result = try await runStreaming(
                    engine: engine, prompt: effectivePrompt,
                    system: effectiveSystem, options: effectiveOptions
                )
            } else {
                result = try await engine.generate(
                    prompt: effectivePrompt, system: effectiveSystem, options: effectiveOptions
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

            // Print speed summary to stderr
            printSpeedSummary(result)
        } catch {
            // Error path: free engine + backend cleanly, then re-throw so
            // ArgumentParser prints the error and exits non-zero.
            // Do NOT call _exit here — the error must surface normally.
            await engine.unload()
            LocalLLMRuntime.shutdown()
            throw error
        }

        // Success path: ordered teardown, then hard-exit to bypass static destructors.
        await engine.unload()
        LocalLLMRuntime.shutdown()
        fflush(stdout)
        fflush(stderr)

        // Fallback: if the upstream ggml-metal rsets assert still fires despite correct
        // teardown order (observed in some llama.cpp builds — see tobi/qmd#674), bypass
        // the C++ static destructors entirely. This is CLI-only; never in the library.
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
        engine: LLMEngine,
        prompt: String,
        system: String?,
        options: GenerationOptions
    ) async throws -> GenerationResult {
        let stream = await engine.generateStreaming(
            prompt: prompt, system: system, options: options
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
