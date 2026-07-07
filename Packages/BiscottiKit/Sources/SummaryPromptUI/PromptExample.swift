/// A pre-canned example block that can be appended to the prompt.
public struct PromptExample: Sendable, Identifiable {
    /// Display name shown on the chip (e.g. "Slack recap").
    public let name: String

    /// The markdown block appended to the prompt.
    public let block: String

    public var id: String {
        name
    }

    public init(name: String, block: String) {
        self.name = name
        self.block = block
    }
}

// MARK: - Built-in examples

public extension PromptExample {
    /// The shipped section blocks. Most are formatted as a `## Heading`
    /// plus a one-line description so appending any block after the default
    /// prompt's Action Items section yields a consistent, well-formed prompt.
    static let builtIn: [PromptExample] = [
        PromptExample(
            name: "Slack recap",
            block: """
            ## Notes for Slack
            A short, paste-ready recap suitable for dropping in a team channel \u{2014} four lines max.
            """
        ),
        PromptExample(
            name: "Meeting feedback",
            block: """
            ## Meeting Feedback
            Three things the meeting did well, and three that could be improved.
            """
        ),
        PromptExample(
            name: "Decisions",
            block: """
            ## Decisions
            Every decision made during the meeting, and who owns each one.
            """
        ),
        PromptExample(
            name: "Key quotes",
            block: """
            ## Key Quotes
            Two to three notable verbatim quotes from the transcript.
            """
        ),
        PromptExample(
            name: "Sentiment",
            block: """
            ## Sentiment & Tone
            A read on the overall mood and energy of the room.
            """
        ),
        PromptExample(
            name: "Make No Mistakes",
            block: "Make no mistakes"
        )
    ]
}
