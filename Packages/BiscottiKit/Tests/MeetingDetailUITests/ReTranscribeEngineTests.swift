import BiscottiTestSupport
import Foundation
import Testing
import Transcription
import TranscriptionService
@testable import AppCore
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

// MARK: - Re-transcribe with engine (Phase 6)

@Suite("MeetingDetailViewModel -- re-transcribe with engine")
@MainActor
struct MeetingDetailReTranscribeEngineTests {
    @Test("reTranscribe(with: .apple) passes apple config with saved locale")
    func reTranscribeWithApple() async throws {
        let fix = try makeCoreFixture(
            appleAvailability: .available,
            appleLocales: ["en_US"],
            appleEquivalent: "en_US",
            appleInstalled: ["en_US"],
            whisperPresent: true,
            testName: "ReTranscribeWithEngine"
        )
        defer { fix.cleanup() }

        await fix.speechEngines.refresh()
        #expect(fix.speechEngines.appleLocale == "en_US")

        let meetingID = try await fix.createMeetingWithAudio()
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        await viewModel.reTranscribe(with: .apple)

        #expect(fix.fakeEngine.backing.lastConfig?.engine == .apple)
        #expect(fix.fakeEngine.backing.lastConfig?.locale == "en_US")
    }

    @Test("reTranscribe(with: .whisper) passes whisper config")
    func reTranscribeWithWhisper() async throws {
        let fix = try makeCoreFixture(
            appleAvailability: .available,
            appleLocales: ["en_US"],
            appleEquivalent: "en_US",
            appleInstalled: ["en_US"],
            testName: "ReTranscribeWithEngine"
        )
        defer { fix.cleanup() }

        await fix.speechEngines.refresh()
        await fix.speechEngines.choose(.apple)

        let meetingID = try await fix.createMeetingWithAudio()
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        await viewModel.reTranscribe(with: .whisper)

        #expect(fix.fakeEngine.backing.lastConfig?.engine == .whisper)
    }

    @Test("currentTranscriptEngine reads engine from newest version methodId")
    func currentTranscriptEngineFromMethodId() async throws {
        let fix = try makeCoreFixture(testName: "ReTranscribeWithEngine")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()

        // Create a transcript with apple-v1 method
        var appleResult = FakeTranscriber.defaultResult
        appleResult = TranscriptResult(
            id: UUID(),
            createdAt: Date(),
            transcriptionMethodId: "apple-v1",
            language: "en_US",
            speakerCount: 2,
            segments: appleResult.segments,
            processingDuration: 1.0
        )
        let txID = try await fix.store.addTranscript(
            appleResult,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        try await fix.store.setPreferredTranscript(txID, for: meetingID)

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(viewModel.currentTranscriptEngine == .apple)
    }

    @Test("currentTranscriptEngine maps empty methodId to whisper")
    func emptyMethodIdMapsToWhisper() async throws {
        let fix = try makeCoreFixture(testName: "ReTranscribeWithEngine")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()

        // Create a transcript with empty method ID (legacy)
        let legacyResult = TranscriptResult(
            id: UUID(),
            createdAt: Date(),
            transcriptionMethodId: "",
            language: "en",
            speakerCount: 1,
            segments: FakeTranscriber.defaultResult.segments,
            processingDuration: 1.0
        )
        let txID = try await fix.store.addTranscript(
            legacyResult,
            vocabularyUsed: [],
            mappedEventIdentifier: nil,
            to: meetingID
        )
        try await fix.store.setPreferredTranscript(txID, for: meetingID)

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(viewModel.currentTranscriptEngine == .whisper)
    }

    @Test("currentTranscriptEngine is nil when no versions exist")
    func noVersionsReturnsNil() async throws {
        let fix = try makeCoreFixture(testName: "ReTranscribeWithEngine")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()

        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        #expect(viewModel.currentTranscriptEngine == nil)
    }

    @Test("reTranscribeMenuItems reflects engine states")
    func menuItemsReflectEngineStates() async throws {
        let fix = try makeCoreFixture(
            appleAvailability: .requiresOSUpdate(currentMajor: 15),
            whisperPresent: true,
            testName: "ReTranscribeWithEngine"
        )
        defer { fix.cleanup() }

        await fix.speechEngines.refresh()

        let meetingID = try await fix.createMeetingWithAudio()
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        let items = viewModel.reTranscribeMenuItems
        #expect(items.count == 2)
        // Apple disabled on macOS 15
        #expect(items[0].engine == .apple)
        #expect(items[0].isEnabled == false)
        #expect(items[0].title.contains("requires macOS 26"))
        // Whisper enabled
        #expect(items[1].engine == .whisper)
        #expect(items[1].isEnabled == true)
    }

    @Test("Transcribe now path passes no override")
    func transcribeNowNoOverride() async throws {
        let fix = try makeCoreFixture(
            whisperPresent: true,
            testName: "ReTranscribeWithEngine"
        )
        defer { fix.cleanup() }

        await fix.speechEngines.refresh()

        let meetingID = try await fix.createMeetingWithAudio()
        let viewModel = MeetingDetailViewModel(
            core: fix.core, meetingID: meetingID
        )
        await viewModel.load()

        // The no-arg reTranscribe (Transcribe now) uses the target engine
        await viewModel.reTranscribe()

        // Should use target's config (whisper)
        #expect(fix.fakeEngine.backing.lastConfig?.engine == .whisper)
    }
}
