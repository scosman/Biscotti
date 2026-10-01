import ArgumentParser

@main
struct VoiceprintCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "voiceprint-cli",
        abstract: "Developer tools for voiceprint management and evaluation.",
        discussion: """
        Backfill voiceprints from existing meetings, or evaluate matching accuracy.

        Both commands refuse to run while the Biscotti app is open — two processes
        must not open the same SwiftData store concurrently.
        """,
        subcommands: [BackfillCommand.self, MetricsCommand.self]
    )
}
