import ArgumentParser

/// CLI for the LocalLLM library.
///
/// Subcommands: download, run.
@main
struct LocalLLMCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "localllm",
        abstract: "Local LLM CLI — drive Gemma 4 inference from the command line.",
        version: "0.1.0",
        subcommands: [DownloadCommand.self, RunCommand.self],
        defaultSubcommand: RunCommand.self
    )
}
