import AppKit
import BiscottiTestSupport
import DataStore
import Foundation
import Testing
import Transcription
@testable import AppCore
@testable import MeetingDetailUI

/// Fake player for copy-transcript tests. Reuses the same shape as
/// FakeAudioPlayer (Phase 8) but is file-local to avoid type conflicts.
private final class CopyFakePlayer: AudioPlaybackProviding,
    @unchecked Sendable
{
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 120
    var rate: Float = 1.0

    func play() {
        isPlaying = true
    }

    func pause() {
        isPlaying = false
    }

    func load(urls _: [URL]) throws {}
}

/// Builds a two-speaker transcript result for copy tests.
private func makeTwoSpeakerResult() -> TranscriptResult {
    TranscriptResult(
        id: UUID(),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        transcriptionMethodId: "v1",
        language: "en",
        speakerCount: 2,
        segments: [
            TranscriptSegment(
                id: UUID(), speakerID: 0, speakerLabel: "Alice",
                startTime: 14.0, endTime: 25.0,
                text: "Hello everyone.",
                confidence: 0.95, noSpeechProbability: 0.01, words: nil
            ),
            TranscriptSegment(
                id: UUID(), speakerID: 1, speakerLabel: "Bob",
                startTime: 31.0, endTime: 45.0,
                text: "Good morning.",
                confidence: 0.95, noSpeechProbability: 0.01, words: nil
            )
        ],
        speakerEmbeddings: [:],
        processingDuration: 1.0
    )
}

@Suite("MeetingDetailViewModel -- copyTranscript")
struct CopyTranscriptTests {
    @Test("copyTranscript writes plain text to pasteboard")
    @MainActor
    func copyTranscriptWritesToPasteboard() async throws {
        let fix = try makeCoreFixture(testName: "CopyTranscript")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let result = makeTwoSpeakerResult()
        let transcriptID = try await fix.store.addTranscript(
            result,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        try await fix.store.setPreferredTranscript(
            transcriptID, for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { CopyFakePlayer() }
        )
        await viewModel.load()

        viewModel.copyTranscript()

        let pasted = NSPasteboard.general.string(forType: .string)
        #expect(
            pasted
                == "Alice  0:14\nHello everyone.\n\nBob  0:31\nGood morning."
        )
    }

    @Test("copyTranscript is no-op when no transcript")
    @MainActor
    func copyTranscriptNoOpWhenEmpty() async throws {
        let fix = try makeCoreFixture(testName: "CopyTranscript")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "No Transcript"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { CopyFakePlayer() }
        )
        await viewModel.load()

        // Clear pasteboard and try to copy
        NSPasteboard.general.clearContents()
        viewModel.copyTranscript()

        // Pasteboard should still be empty (no transcript to copy)
        let pasted = NSPasteboard.general.string(forType: .string)
        #expect(pasted == nil)
    }
}
