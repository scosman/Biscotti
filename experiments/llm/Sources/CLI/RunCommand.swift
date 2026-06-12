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

        // Load engine
        logStderr("Loading model...")
        let engine = try await LLMEngine(modelPath: modelURL, config: engineConfig)
        defer { Task { await engine.unload() } }

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

        // Generate (streaming or buffered)
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
            // Print the model's message to stdout (clean, pipeable)
            print(result.text)
        }

        // Print speed summary to stderr
        printSpeedSummary(result)
    }

    // MARK: - Helpers

    /// Stream tokens to stdout as they arrive, returning the final result.
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
        for try await event in stream {
            switch event {
            case let .token(piece):
                // Print each token immediately without a trailing newline
                print(piece, terminator: "")
                fflush(stdout)
            case let .done(result):
                finalResult = result
            }
        }

        // Ensure stdout ends with a newline after streaming
        print("")

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
