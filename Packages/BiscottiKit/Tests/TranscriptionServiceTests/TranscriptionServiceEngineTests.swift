import BiscottiTestSupport
import Foundation
import Testing
import Transcription
import TranscriptionService
@testable import DataStore

@Suite("TranscriptionService -- engine wiring")
@MainActor
struct TranscriptionServiceEngineTests {
    @Test("Apple target sends apple config and empty vocab")
    func appleTargetConfigAndVocab() async throws {
        let fix = try makeCoreFixture(
            appleAvailability: .available,
            appleLocales: ["en_US"],
            appleEquivalent: "en_US",
            appleInstalled: ["en_US"],
            testName: "TSEngine"
        )
        defer { fix.cleanup() }

        await fix.speechEngines.refresh()
        await fix.speechEngines.choose(.apple)
        #expect(fix.speechEngines.target == .apple)

        let meetingID = try await fix.createMeetingWithAudio()
        await fix.core.transcription.transcribe(meetingID: meetingID)

        // Apple jobs use .apple config
        #expect(fix.fakeEngine.backing.lastConfig?.engine == .apple)
        // Apple jobs send empty vocabulary (no custom vocab support)
        #expect(fix.fakeEngine.backing.lastVocabulary == [])
        // Apple jobs download only .speakerID, not .whisper
        let components = fix.fakeEngine.backing.lastComponents
        #expect(components != nil)
        #expect(components?.contains(.speakerID) == true)
        #expect(components?.contains(.whisper) == false)
    }

    @Test("Whisper target sends whisper config and vocabulary")
    func whisperTargetConfigAndVocab() async throws {
        let fix = try makeCoreFixture(
            whisperPresent: true,
            testName: "TSEngine"
        )
        defer { fix.cleanup() }

        await fix.speechEngines.refresh()
        #expect(fix.speechEngines.target == .whisper)

        // Enable custom vocabulary with terms
        try await fix.store.updateSettings {
            $0.customVocabularyEnabled = true
            $0.customVocabulary = ["Biscotti", "ArgMax"]
        }

        let meetingID = try await fix.createMeetingWithAudio()
        await fix.core.transcription.transcribe(meetingID: meetingID)

        // Whisper jobs use .whisper config
        #expect(fix.fakeEngine.backing.lastConfig?.engine == .whisper)
        // Whisper jobs include vocabulary terms
        let vocab = fix.fakeEngine.backing.lastVocabulary ?? []
        #expect(!vocab.isEmpty)
        // Whisper jobs download .all components
        #expect(fix.fakeEngine.backing.lastComponents == .all)
    }

    @Test("speechEngines.refresh called after job completes")
    func refreshCalledAfterJob() async throws {
        let fix = try makeCoreFixture(
            whisperPresent: true,
            testName: "TSEngine"
        )
        defer { fix.cleanup() }

        await fix.speechEngines.refresh()
        let countBefore = fix.managerEngine.backing.modelsPresentCallCount

        let meetingID = try await fix.createMeetingWithAudio()
        await fix.core.transcription.transcribe(meetingID: meetingID)

        // refresh() calls modelsPresent on the manager engine
        let countAfter = fix.managerEngine.backing.modelsPresentCallCount
        #expect(countAfter > countBefore)
    }
}
