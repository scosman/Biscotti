import BiscottiTestSupport
import Foundation
import Testing
import Transcription
import TranscriptionService
@testable import DataStore
@testable import MeetingDetailUI

@Suite("MeetingDetailViewModel -- re-transcribe engine gate")
@MainActor
struct ReTranscribeEngineTests {
    @Test("shouldOfferReTranscribe returns false when target is Apple")
    func notOfferedWhenApple() async throws {
        let fix = try makeCoreFixture(
            appleAvailability: .available,
            appleLocales: ["en_US"],
            appleEquivalent: "en_US",
            appleInstalled: ["en_US"],
            testName: "ReTranscribeEngine"
        )
        defer { fix.cleanup() }

        await fix.speechEngines.refresh()
        await fix.speechEngines.choose(.apple)
        #expect(fix.speechEngines.target == .apple)

        let meetingID = try await fix.createMeetingWithAudio()

        // Enable vocabulary so all other preconditions pass
        try await fix.store.updateSettings {
            $0.customVocabularyEnabled = true
            $0.customVocabulary = ["Kubernetes"]
        }

        // Transcript recorded with no vocabulary (mismatch exists)
        let txResult = FakeTranscriber.defaultResult
        let transcriptID = try await fix.store.addTranscript(
            txResult,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        try await fix.store.setPreferredTranscript(transcriptID, for: meetingID)

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        let offer = await viewModel.shouldOfferReTranscribe()
        #expect(offer == false)
    }

    @Test("shouldOfferReTranscribe returns true when target is Whisper and vocab differs")
    func offeredWhenWhisperAndVocabDiffers() async throws {
        let fix = try makeCoreFixture(
            whisperPresent: true,
            testName: "ReTranscribeEngine"
        )
        defer { fix.cleanup() }

        await fix.speechEngines.refresh()
        #expect(fix.speechEngines.target == .whisper)

        let meetingID = try await fix.createMeetingWithAudio()

        // Enable vocabulary with terms
        try await fix.store.updateSettings {
            $0.customVocabularyEnabled = true
            $0.customVocabulary = ["Kubernetes"]
        }

        // Transcript recorded with no vocabulary (mismatch)
        let txResult = FakeTranscriber.defaultResult
        let transcriptID = try await fix.store.addTranscript(
            txResult,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        try await fix.store.setPreferredTranscript(transcriptID, for: meetingID)

        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()

        let offer = await viewModel.shouldOfferReTranscribe()
        #expect(offer == true)
    }
}
