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
    /// The five shipped example blocks from the functional spec.
    static let builtIn: [PromptExample] = [
        PromptExample(
            name: "Slack recap",
            block: """
            ## Notes for Slack
            A short, paste-ready recap I can drop in our team channel \u{2014} 4 lines max.
            """
        ),
        PromptExample(
            name: "Meeting feedback",
            block: """
            ## Meeting Feedback
            3 things I did well, and 3 I could do better.
            """
        ),
        PromptExample(
            name: "Decisions",
            block: """
            ## Decisions
            Every decision made, and who owns it.
            """
        ),
        PromptExample(
            name: "Key quotes",
            block: """
            ## Key Quotes
            2\u{2013}3 notable verbatim quotes.
            """
        ),
        PromptExample(
            name: "Sentiment",
            block: """
            ## Sentiment & Tone
            A read on the mood and energy of the room.
            """
        )
    ]
}
