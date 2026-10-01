import AppLinks
import BiscottiTestSupport
import DataStore
import Foundation
import Testing
@testable import AppCore
@testable import MeetingDetailUI

// MARK: - DeepLinkFakePlayer (local copy for this test file)

/// A fake audio player for testing intent-seek behavior.
private final class DeepLinkFakePlayer: AudioPlaybackProviding,
    @unchecked Sendable
{
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 120 // 2 minutes
    var rate: Float = 1.0
    var loadedURLs: [URL] = []

    func play() {
        isPlaying = true
    }

    func pause() {
        isPlaying = false
    }

    func load(urls: [URL]) throws {
        loadedURLs = urls
    }
}

// MARK: - Open-meeting intent application tests

@Suite("MeetingDetailViewModel -- open-meeting intent")
struct MeetingOpenIntentTests {
    @Test("transcript-time intent switches tab and seeks")
    @MainActor
    func transcriptTimeIntentSwitchesTabAndSeeks() async throws {
        let fix = try makeCoreFixture(testName: "MeetingOpenIntent")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio(
            recordingDuration: 120
        )

        let fakePlayer = DeepLinkFakePlayer()
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { fakePlayer }
        )

        // Start on notes tab to verify the switch
        viewModel.selectedTab = .notes
        await viewModel.load()

        await fix.core.apply(
            .meeting(id: meetingID, target: .transcriptTime(42.0))
        )
        #expect(fix.core.pendingMeetingIntent != nil)

        await viewModel.applyPendingIntentIfNeeded()

        #expect(viewModel.selectedTab == .transcript)
        #expect(fakePlayer.currentTime == 42.0)
        #expect(fix.core.pendingMeetingIntent == nil)
    }

    @Test("tab intent opens the requested tab without seeking")
    @MainActor
    func tabIntentSwitchesTabWithoutSeek() async throws {
        let fix = try makeCoreFixture(testName: "MeetingOpenIntent")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio(
            recordingDuration: 120
        )

        let fakePlayer = DeepLinkFakePlayer()
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { fakePlayer }
        )
        await viewModel.load()
        #expect(viewModel.selectedTab == .summary)

        await fix.core.apply(.meeting(id: meetingID, target: .tab(.notes)))

        await viewModel.applyPendingIntentIfNeeded()

        #expect(viewModel.selectedTab == .notes)
        #expect(fakePlayer.currentTime == 0)
        #expect(fakePlayer.isPlaying == false)
        #expect(fix.core.pendingMeetingIntent == nil)
    }

    @Test("seek is clamped to audio duration")
    @MainActor
    func seekClampedToDuration() async throws {
        let fix = try makeCoreFixture(testName: "MeetingOpenIntent")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio(
            recordingDuration: 60
        )

        let fakePlayer = DeepLinkFakePlayer()
        fakePlayer.duration = 60
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { fakePlayer }
        )
        await viewModel.load()

        await fix.core.apply(
            .meeting(id: meetingID, target: .transcriptTime(999.0))
        )
        await viewModel.applyPendingIntentIfNeeded()

        #expect(fakePlayer.currentTime == 60.0)
        #expect(viewModel.selectedTab == .transcript)
    }

    @Test("intent for a different meeting is ignored")
    @MainActor
    func intentForDifferentMeetingIgnored() async throws {
        let fix = try makeCoreFixture(testName: "MeetingOpenIntent")
        defer { fix.cleanup() }

        let meetingA = try await fix.createMeetingWithAudio(
            title: "Meeting A", recordingDuration: 120
        )
        let meetingB = try await fix.createMeetingWithAudio(
            title: "Meeting B", recordingDuration: 120
        )

        let fakePlayer = DeepLinkFakePlayer()
        // VM is for meeting A
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingA,
            makePlayer: { fakePlayer }
        )
        viewModel.selectedTab = .notes
        await viewModel.load()

        // Intent targets meeting B
        await fix.core.apply(
            .meeting(id: meetingB, target: .transcriptTime(42.0))
        )

        await viewModel.applyPendingIntentIfNeeded()

        // VM for meeting A should not be affected
        #expect(viewModel.selectedTab == .notes)
        #expect(fakePlayer.currentTime == 0)
        // The intent should NOT have been consumed (it's for meeting B)
        #expect(fix.core.pendingMeetingIntent != nil)
    }

    @Test("intent arriving before audio loads is deferred then applied")
    @MainActor
    func deferredIntentAppliedAfterAudioLoad() async throws {
        let fix = try makeCoreFixture(testName: "MeetingOpenIntent")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Deferred Intent"
        )

        let fakePlayer = DeepLinkFakePlayer()
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { fakePlayer }
        )

        // Set up a pending intent BEFORE load (no audio yet)
        await fix.core.apply(
            .meeting(id: meetingID, target: .transcriptTime(30.0))
        )

        // Apply intent -- audio not loaded, so seek should be deferred
        await viewModel.applyPendingIntentIfNeeded()

        #expect(viewModel.selectedTab == .transcript)
        // Player has no audio, so currentTime stays 0
        #expect(fakePlayer.currentTime == 0)
        // Intent was consumed (tab switch happened)
        #expect(fix.core.pendingMeetingIntent == nil)

        // Now attach audio and reload -- the deferred seek should apply
        let micRef = AudioFileRef(
            role: .mic,
            path: "/tmp/test/mic.aac",
            byteSize: 1024,
            isPresent: true
        )
        try await fix.store.attachAudio([micRef], to: meetingID)

        await viewModel.load()

        // After loadAudioPlayer, the deferred seek should be applied
        #expect(fakePlayer.currentTime == 30.0)
    }

    @Test("consumeMeetingIntent is called after applying the intent")
    @MainActor
    func consumeCalledAfterApply() async throws {
        let fix = try makeCoreFixture(testName: "MeetingOpenIntent")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio(
            recordingDuration: 120
        )

        let fakePlayer = DeepLinkFakePlayer()
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { fakePlayer }
        )
        await viewModel.load()

        await fix.core.apply(
            .meeting(id: meetingID, target: .transcriptTime(50.0))
        )
        #expect(fix.core.pendingMeetingIntent != nil)

        await viewModel.applyPendingIntentIfNeeded()

        #expect(fix.core.pendingMeetingIntent == nil)
        #expect(fakePlayer.currentTime == 50.0)
    }

    @Test("no pending intent is a no-op")
    @MainActor
    func noPendingIntentIsNoOp() async throws {
        let fix = try makeCoreFixture(testName: "MeetingOpenIntent")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio(
            recordingDuration: 120
        )

        let fakePlayer = DeepLinkFakePlayer()
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { fakePlayer }
        )
        viewModel.selectedTab = .notes
        await viewModel.load()

        // No intent set
        await viewModel.applyPendingIntentIfNeeded()

        // Nothing changed
        #expect(viewModel.selectedTab == .notes)
        #expect(fakePlayer.currentTime == 0)
    }

    @Test("a repeated identical intent re-applies (token differs)")
    @MainActor
    func repeatedIdenticalIntentReapplies() async throws {
        let fix = try makeCoreFixture(testName: "MeetingOpenIntent")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio(
            recordingDuration: 120
        )

        let fakePlayer = DeepLinkFakePlayer()
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { fakePlayer }
        )
        await viewModel.load()

        let link = AppLink.meeting(id: meetingID, target: .tab(.notes))

        // First link: notes tab
        await fix.core.apply(link)
        let firstToken = fix.core.pendingMeetingIntent?.token
        await viewModel.applyPendingIntentIfNeeded()
        #expect(viewModel.selectedTab == .notes)

        // Second identical link must still register via a distinct token
        await fix.core.apply(link)
        let secondToken = fix.core.pendingMeetingIntent?.token
        #expect(secondToken != firstToken)
        viewModel.selectedTab = .summary
        await viewModel.applyPendingIntentIfNeeded()
        #expect(viewModel.selectedTab == .notes)
    }
}
