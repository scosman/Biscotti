import BiscottiTestSupport
import Foundation
import Testing
import Transcription
import TranscriptionService
@testable import DataStore

@Suite("TranscriptionService -- re-transcribe engine override")
@MainActor
struct TranscriptionServiceOverrideTests {
    @Test("Whisper override with Apple target sends whisper config and vocab")
    func whisperOverrideWithAppleTarget() async throws {
        let fix = try makeCoreFixture(
            appleAvailability: .available,
            appleLocales: ["en_US"],
            appleEquivalent: "en_US",
            appleInstalled: ["en_US"],
            testName: "TSOverride"
        )
        defer { fix.cleanup() }

        await fix.speechEngines.refresh()
        await fix.speechEngines.choose(.apple)
        #expect(fix.speechEngines.target == .apple)

        // Enable custom vocabulary (stored preference on)
        try await fix.store.updateSettings {
            $0.customVocabularyEnabled = true
            $0.customVocabulary = ["Biscotti", "ArgMax"]
        }

        let meetingID = try await fix.createMeetingWithAudio()
        await fix.core.transcription.reTranscribe(
            meetingID: meetingID, config: .whisper()
        )

        // Override sends whisper config
        #expect(fix.fakeEngine.backing.lastConfig?.engine == .whisper)
        // Override sends .all components (whisper needs both whisper + speakerID)
        #expect(fix.fakeEngine.backing.lastComponents == .all)
        // Override sends vocab even though target is Apple
        let vocab = fix.fakeEngine.backing.lastVocabulary ?? []
        #expect(!vocab.isEmpty)
    }

    @Test("Apple override with Whisper target sends apple config and empty vocab")
    func appleOverrideWithWhisperTarget() async throws {
        let fix = try makeCoreFixture(
            appleAvailability: .available,
            appleLocales: ["en_US"],
            appleEquivalent: "en_US",
            appleInstalled: ["en_US"],
            whisperPresent: true,
            testName: "TSOverride"
        )
        defer { fix.cleanup() }

        await fix.speechEngines.refresh()
        await fix.speechEngines.choose(.whisper)
        #expect(fix.speechEngines.target == .whisper)

        // Enable custom vocabulary
        try await fix.store.updateSettings {
            $0.customVocabularyEnabled = true
            $0.customVocabulary = ["Kubernetes"]
        }

        let meetingID = try await fix.createMeetingWithAudio()
        await fix.core.transcription.reTranscribe(
            meetingID: meetingID, config: .apple(locale: "en_US")
        )

        // Override sends apple config
        #expect(fix.fakeEngine.backing.lastConfig?.engine == .apple)
        #expect(fix.fakeEngine.backing.lastConfig?.locale == "en_US")
        // Apple override sends only .speakerID
        let components = fix.fakeEngine.backing.lastComponents
        #expect(components != nil)
        #expect(components?.contains(.speakerID) == true)
        #expect(components?.contains(.whisper) == false)
        // Apple override sends empty vocab
        #expect(fix.fakeEngine.backing.lastVocabulary == [])
    }

    @Test("Nil override uses target engine (regression)")
    func nilOverrideUsesTarget() async throws {
        let fix = try makeCoreFixture(
            whisperPresent: true,
            testName: "TSOverride"
        )
        defer { fix.cleanup() }

        await fix.speechEngines.refresh()
        #expect(fix.speechEngines.target == .whisper)

        let meetingID = try await fix.createMeetingWithAudio()
        await fix.core.transcription.reTranscribe(
            meetingID: meetingID, config: nil
        )

        #expect(fix.fakeEngine.backing.lastConfig?.engine == .whisper)
        #expect(fix.fakeEngine.backing.lastComponents == .all)
    }

    @Test("Selection unchanged after override job")
    func selectionUnchangedAfterOverride() async throws {
        let fix = try makeCoreFixture(
            appleAvailability: .available,
            appleLocales: ["en_US"],
            appleEquivalent: "en_US",
            appleInstalled: ["en_US"],
            whisperPresent: true,
            testName: "TSOverride"
        )
        defer { fix.cleanup() }

        await fix.speechEngines.refresh()
        // Explicitly select Whisper
        await fix.speechEngines.choose(.whisper)
        #expect(fix.speechEngines.selection == .whisper)

        let meetingID = try await fix.createMeetingWithAudio()
        // Run an Apple override
        await fix.core.transcription.reTranscribe(
            meetingID: meetingID, config: .apple(locale: "en_US")
        )

        // Selection must still be Whisper (override never writes selection)
        #expect(fix.speechEngines.selection == .whisper)
        #expect(fix.speechEngines.target == .whisper)
    }

    @Test("Whisper override stores vocabulary used from stored preference")
    func whisperOverrideStoresVocab() async throws {
        let fix = try makeCoreFixture(
            appleAvailability: .available,
            appleLocales: ["en_US"],
            appleEquivalent: "en_US",
            appleInstalled: ["en_US"],
            testName: "TSOverride"
        )
        defer { fix.cleanup() }

        await fix.speechEngines.refresh()
        await fix.speechEngines.choose(.apple)

        try await fix.store.updateSettings {
            $0.customVocabularyEnabled = true
            $0.customVocabulary = ["Biscotti"]
        }

        let meetingID = try await fix.createMeetingWithAudio()
        await fix.core.transcription.reTranscribe(
            meetingID: meetingID, config: .whisper()
        )

        // Verify the transcript was persisted with vocabulary
        let detail = try await fix.store.meetingDetail(id: meetingID)
        let vocabUsed = detail?.versions.first?.vocabularyUsed ?? []
        #expect(vocabUsed.contains("Biscotti"))
    }
}
