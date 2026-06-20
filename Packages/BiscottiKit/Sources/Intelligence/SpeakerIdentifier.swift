import DataStore
import Foundation
import LocalLLM

/// Runs the speaker-identification step: build prompt, generate, parse, resolve
/// people via DataStore, and persist the speaker assignments.
enum SpeakerIdentifier {
    /// Generation options for speaker identification: low temperature, small
    /// max tokens (a few hundred -- one short line per speaker), no thinking.
    static let generationOptions = GenerationOptions(
        maxTokens: 512,
        temperature: 0.2,
        thinking: .off
    )

    /// Runs speaker identification for a transcript.
    ///
    /// - Parameters:
    ///   - session: The LLM session to use for generation.
    ///   - transcript: The transcript to identify speakers in.
    ///   - invitees: Calendar invitees as `(name, email?)` pairs.
    ///   - store: DataStore for person resolution and persistence.
    /// - Returns: A map of speaker ID to resolved display name, for use by
    ///   the downstream summary step.
    @MainActor
    static func run(
        _ session: any LLMSession,
        _ transcript: TranscriptData,
        _ invitees: [(name: String, email: String?)],
        _ store: DataStore
    ) async throws -> [Int: String] {
        // Build prompt with "Speaker N" labels (no names yet)
        let formattedTranscript = TranscriptFormatter.plain(
            transcript, names: [:]
        )
        let userMessage = IntelligencePrompts.speakerUser(
            transcript: formattedTranscript, invitees: invitees
        )

        // Generate
        let raw = try await session.generate(
            system: IntelligencePrompts.speakerSystem,
            user: userMessage,
            options: generationOptions
        )

        // Parse
        let parsed = SpeakerMappingParser.parse(raw)

        // Resolve people and build assignments
        var assignments: [Int: UUID] = [:]
        var nameMap: [Int: String] = [:]

        for (speakerID, mapping) in parsed {
            let personID = try await store.findOrCreatePerson(
                name: mapping.name, email: mapping.email
            )
            assignments[speakerID] = personID
            nameMap[speakerID] = mapping.name
        }

        // Persist
        try await store.setSpeakerAssignments(
            assignments, for: transcript.id
        )

        return nameMap
    }
}
