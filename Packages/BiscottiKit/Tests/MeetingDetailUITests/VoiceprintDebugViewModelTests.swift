#if DEBUG

    import BiscottiTestSupport
    import DataStore
    import Foundation
    import Testing
    import Transcription
    @testable import AppCore
    @testable import Intelligence
    @testable import MeetingDetailUI

    @Suite("MeetingDetailViewModel voiceprint debug")
    struct VoiceprintDebugViewModelTests {
        @Test("openVoiceprintDebug populates voiceprintDebug")
        @MainActor
        func openSetsProperty() async throws {
            let fix = try makeCoreFixture(testName: "VoiceprintDebugVMTests")
            defer { fix.cleanup() }

            let meetingID = try await fix.createMeetingWithAudio()
            let result = FakeTranscriber.defaultResult
            let transcriptID = try await fix.store.addTranscript(
                result,
                vocabularyUsed: [],
                mappedEventIdentifier: nil,
                to: meetingID
            )
            try await fix.store.setPreferredTranscript(transcriptID, for: meetingID)

            let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
            await viewModel.load()

            #expect(viewModel.voiceprintDebug == nil)

            await viewModel.openVoiceprintDebug(speakerID: 0)

            let model = try #require(viewModel.voiceprintDebug)
            #expect(model.report.speakerID == 0)
            #expect(model.report.kind == .plda)
        }

        @Test("reloadVoiceprintDebug replaces report with new kind")
        @MainActor
        func reloadReplacesReport() async throws {
            let fix = try makeCoreFixture(testName: "VoiceprintDebugVMTests")
            defer { fix.cleanup() }

            let meetingID = try await fix.createMeetingWithAudio()
            let result = FakeTranscriber.defaultResult
            let transcriptID = try await fix.store.addTranscript(
                result,
                vocabularyUsed: [],
                mappedEventIdentifier: nil,
                to: meetingID
            )
            try await fix.store.setPreferredTranscript(transcriptID, for: meetingID)

            let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
            await viewModel.load()

            // Open with default kind (.plda)
            await viewModel.openVoiceprintDebug(speakerID: 0)
            let firstID = viewModel.voiceprintDebug?.id
            #expect(viewModel.voiceprintDebug?.report.kind == .plda)

            // Reload with .raw
            await viewModel.reloadVoiceprintDebug(kind: .raw)

            let reloaded = try #require(viewModel.voiceprintDebug)
            #expect(reloaded.report.kind == .raw)
            #expect(reloaded.report.speakerID == 0)
            // New model has a new ID (replaced, not mutated)
            #expect(reloaded.id != firstID)
        }

        @Test("openVoiceprintDebug is no-op without a transcript")
        @MainActor
        func openNoOpWithoutTranscript() async throws {
            let fix = try makeCoreFixture(testName: "VoiceprintDebugVMTests")
            defer { fix.cleanup() }

            let meetingID = try await fix.createMeetingWithAudio()

            let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
            await viewModel.load()

            await viewModel.openVoiceprintDebug(speakerID: 0)
            #expect(viewModel.voiceprintDebug == nil)
        }
    }

#endif
