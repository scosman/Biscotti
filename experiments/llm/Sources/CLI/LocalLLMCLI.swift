import ArgumentParser

/// Experiment CLI for the LocalLLM library.
///
/// Subcommands (Phase 2): download, run.
/// This is a minimal stub so the package compiles. Real implementation in Phase 2.
@main
struct LocalLLMCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "localllm",
        abstract: "Local LLM experiment CLI — drive Gemma 4 inference from the command line.",
        version: "0.1.0",
        subcommands: []
    )
}
