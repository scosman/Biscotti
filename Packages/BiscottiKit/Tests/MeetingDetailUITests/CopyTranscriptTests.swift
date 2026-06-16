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

// MARK: - Transcript cache tests

@Suite("MeetingDetailViewModel -- transcript cache")
struct TranscriptCacheTests {
    @Test("load populates cachedTranscriptAttributed when transcript exists")
    @MainActor
    func loadPopulatesCache() async throws {
        let fix = try makeCoreFixture(testName: "TxCache")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let result = makeTwoSpeakerResult()
        let transcriptID = try await fix.store.addTranscript(
            result, vocabularyUsed: [], mappedEventIdentifier: nil,
            to: meetingID
        )
        try await fix.store.setPreferredTranscript(
            transcriptID, for: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID,
            makePlayer: { CopyFakePlayer() }
        )
        await viewModel.load()

        #expect(viewModel.cachedTranscriptAttributed != nil)
        #expect(viewModel.hasDisplayableTranscript == true)
    }

    @Test("hasDisplayableTranscript false when no transcript")
    @MainActor
    func hasDisplayableFalseWithoutTranscript() async throws {
        let fix = try makeCoreFixture(testName: "TxCache")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "No Transcript"
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID,
            makePlayer: { CopyFakePlayer() }
        )
        await viewModel.load()

        #expect(viewModel.cachedTranscriptAttributed == nil)
        #expect(viewModel.hasDisplayableTranscript == false)
    }

    @Test("selectVersion rebuilds cache for the new version")
    @MainActor
    func selectVersionRebuildsCache() async throws {
        let fix = try makeCoreFixture(testName: "TxCache")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()
        let result1 = makeTwoSpeakerResult()
        let id1 = try await fix.store.addTranscript(
            result1, vocabularyUsed: [], mappedEventIdentifier: nil,
            to: meetingID
        )
        try await fix.store.setPreferredTranscript(id1, for: meetingID)

        // Add a second version
        let result2 = TranscriptResult(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_001_000),
            transcriptionMethodId: "v2",
            language: "en",
            speakerCount: 1,
            segments: [
                TranscriptSegment(
                    id: UUID(), speakerID: 0, speakerLabel: "Carol",
                    startTime: 0, endTime: 10.0,
                    text: "Version two text.",
                    confidence: 0.9, noSpeechProbability: 0.01, words: nil
                )
            ],
            speakerEmbeddings: [:],
            processingDuration: 1.0
        )
        let id2 = try await fix.store.addTranscript(
            result2, vocabularyUsed: [], mappedEventIdentifier: nil,
            to: meetingID
        )

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID,
            makePlayer: { CopyFakePlayer() }
        )
        await viewModel.load()

        let cachedBefore = viewModel.cachedTranscriptAttributed
        #expect(cachedBefore != nil)

        // Switch to version 2
        await viewModel.selectVersion(id2)

        #expect(viewModel.cachedTranscriptAttributed != nil)
        // Cache should differ because the transcript content changed
        #expect(viewModel.cachedTranscriptAttributed != cachedBefore)
    }
}

// MARK: - copyNotes tests

@Suite("MeetingDetailViewModel -- copyNotes")
struct CopyNotesTests {
    @Test("copyNotes writes notes text to pasteboard")
    @MainActor
    func copyNotesWritesToPasteboard() async throws {
        let fix = try makeCoreFixture(testName: "CopyNotes")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "With Notes")
        try await fix.store.setNotes("Some meeting notes here.", for: meetingID)

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { CopyFakePlayer() }
        )
        await viewModel.load()

        viewModel.copyNotes()

        let pasted = NSPasteboard.general.string(forType: .string)
        #expect(pasted == "Some meeting notes here.")
    }

    @Test("copyNotes is no-op when notes are empty")
    @MainActor
    func copyNotesNoOpWhenEmpty() async throws {
        let fix = try makeCoreFixture(testName: "CopyNotes")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(title: "Empty Notes")

        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { CopyFakePlayer() }
        )
        await viewModel.load()

        NSPasteboard.general.clearContents()
        viewModel.copyNotes()

        let pasted = NSPasteboard.general.string(forType: .string)
        #expect(pasted == nil)
    }
}
