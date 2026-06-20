import BiscottiTestSupport
import DataStore
import Foundation
import Intelligence
import Testing
import Transcription
@testable import AppCore

// MARK: - AppCore Intelligence wiring tests

@Suite("AppCore -- intelligence wiring")
struct AppCoreIntelligenceTests {
    // MARK: - Helpers

    /// Creates a meeting with a persisted transcript, mirroring the
    /// `makeMeetingWithTranscript` pattern from IntelligenceTests.
    private func persistTranscript(
        in store: DataStore, title: String = "AI Test"
    ) async throws -> UUID {
        let meetingID = try await store.createMeeting(title: title)
        let result = TranscriptResult(
            transcriptionMethodId: "v1",
            language: "en",
            speakerCount: 2,
            segments: [
                TranscriptSegment(
                    speakerID: 0, speakerLabel: "Speaker 0",
                    startTime: 0, endTime: 5,
                    text: "Hello everyone", confidence: 0.9,
                    noSpeechProbability: 0.1, words: nil
                ),
                TranscriptSegment(
                    speakerID: 1, speakerLabel: "Speaker 1",
                    startTime: 5, endTime: 10,
                    text: "Hi there", confidence: 0.85,
                    noSpeechProbability: 0.15, words: nil
                )
            ],
            speakerEmbeddings: [:],
            processingDuration: 3.0
        )
        let transcriptID = try await store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await store.setPreferredTranscript(
            transcriptID, for: meetingID
        )
        return meetingID
    }

    // MARK: - stopRecording wiring

    @Test("stopRecording triggers runAutoEnhancements that opens an LLM session")
    @MainActor
    func stopRecordingTriggersAutoEnhancements() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "AppCoreIntelligence"
        )
        defer { fix.cleanup() }

        // Start and stop a recording
        await fix.core.startRecording()
        let meetingID = try #require(await fix.core.stopRecording())

        // The pending task is a @MainActor Task; since we're on
        // @MainActor, its body hasn't started yet. Insert a transcript
        // now so Intelligence finds it when the task runs.
        let result = TranscriptResult(
            transcriptionMethodId: "v1",
            language: "en",
            speakerCount: 1,
            segments: [
                TranscriptSegment(
                    speakerID: 0, speakerLabel: "Speaker 0",
                    startTime: 0, endTime: 5,
                    text: "Hello", confidence: 0.9,
                    noSpeechProbability: 0.1, words: nil
                )
            ],
            speakerEmbeddings: [:],
            processingDuration: 1.0
        )
        let txID = try await fix.store.addTranscript(
            result, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(
            txID, for: meetingID
        )

        // Now let the fire-and-forget task run
        await fix.core.awaitPendingTranscription()

        // Positive evidence: the LLM runner opened a session, proving
        // runAutoEnhancements was called AND reached the LLM path.
        #expect(fix.fakeLLMRunner.sessionCount == 1)

        // Verify the intelligence service is accessible via core
        #expect(fix.core.intelligence === fix.intelligence)
    }

    @Test("stopRecording does not open LLM session when model is not downloaded")
    @MainActor
    func stopRecordingSkipsEnhancementsNoModel() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: false,
            testName: "AppCoreIntelligence"
        )
        defer { fix.cleanup() }

        await fix.core.startRecording()
        _ = try #require(await fix.core.stopRecording())

        await fix.core.awaitPendingTranscription()

        // No LLM session should have been opened
        #expect(fix.fakeLLMRunner.sessionCount == 0)
    }

    // MARK: - intelligence property

    @Test("intelligence property is publicly accessible on AppCore")
    @MainActor
    func intelligencePropertyAccessible() throws {
        let fix = try makeCoreFixture(testName: "AppCoreIntelligence")
        defer { fix.cleanup() }

        // Verify the intelligence service is the same instance
        #expect(fix.core.intelligence === fix.intelligence)

        // Verify model state reflects the fake provider
        #expect(fix.core.intelligence.isModelDownloaded == false)

        // Flip the fake and verify
        fix.fakeModelProvider.downloaded = true
        #expect(fix.core.intelligence.isModelDownloaded == true)
    }

    // MARK: - runAutoEnhancements via AppCore

    @Test("runAutoEnhancements opens LLM session when transcript and model present")
    @MainActor
    func autoEnhancementsRunWithTranscriptAndModel() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "AppCoreIntelligence"
        )
        defer { fix.cleanup() }

        // Create a meeting with a persisted transcript
        let meetingID = try await persistTranscript(in: fix.store)

        // Run enhancements through the AppCore-wired intelligence
        await fix.intelligence.runAutoEnhancements(meetingID: meetingID)

        // Positive evidence: an LLM session was opened
        #expect(fix.fakeLLMRunner.sessionCount == 1)
        #expect(fix.intelligence.jobs[meetingID] == .completed)
    }

    @Test("runAutoEnhancements is a no-op when no transcript exists")
    @MainActor
    func autoEnhancementsNoOpWithoutTranscript() async throws {
        let fix = try makeCoreFixture(
            modelDownloaded: true,
            testName: "AppCoreIntelligence"
        )
        defer { fix.cleanup() }

        // Create a meeting with no transcript
        let meetingID = try await fix.store.createMeeting(
            title: "No Transcript"
        )

        await fix.intelligence.runAutoEnhancements(meetingID: meetingID)

        // Intelligence exits early -- no session opened
        #expect(fix.fakeLLMRunner.sessionCount == 0)
        #expect(fix.intelligence.jobs[meetingID] == nil)
    }
}
