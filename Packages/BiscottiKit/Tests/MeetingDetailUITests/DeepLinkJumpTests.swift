import BiscottiTestSupport
import DataStore
import Foundation
import Testing
@testable import AppCore
@testable import MeetingDetailUI

// MARK: - DeepLinkFakePlayer (local copy for this test file)

/// A fake audio player for testing deep-link seek behavior.
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

// MARK: - Deep-link jump application tests

@Suite("MeetingDetailViewModel -- deep link jump")
struct DeepLinkJumpTests {
    @Test("pending jump for this meeting switches to transcript tab and seeks")
    @MainActor
    func pendingJumpSwitchesTabAndSeeks() async throws {
        let fix = try makeCoreFixture(testName: "DeepLinkJumpTests")
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

        // Simulate a deep-link jump arriving
        let url = try #require(URL(
            string: "biscotti://meeting/\(meetingID.uuidString)?time=42.0"
        ))
        await fix.core.handleDeepLink(url)
        #expect(fix.core.pendingTranscriptJump != nil)

        // Apply the jump
        await viewModel.applyPendingJumpIfNeeded()

        #expect(viewModel.selectedTab == .transcript)
        #expect(fakePlayer.currentTime == 42.0)
        // Jump should be consumed
        #expect(fix.core.pendingTranscriptJump == nil)
    }

    @Test("seek is clamped to audio duration")
    @MainActor
    func seekClampedToDuration() async throws {
        let fix = try makeCoreFixture(testName: "DeepLinkJumpTests")
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

        // Jump beyond the duration
        let url = try #require(URL(
            string: "biscotti://meeting/\(meetingID.uuidString)?time=999.0"
        ))
        await fix.core.handleDeepLink(url)

        await viewModel.applyPendingJumpIfNeeded()

        // Should be clamped to duration (60)
        #expect(fakePlayer.currentTime == 60.0)
        #expect(viewModel.selectedTab == .transcript)
    }

    @Test("pending jump for a different meeting is ignored")
    @MainActor
    func jumpForDifferentMeetingIgnored() async throws {
        let fix = try makeCoreFixture(testName: "DeepLinkJumpTests")
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

        // Deep-link targets meeting B
        let url = try #require(URL(
            string: "biscotti://meeting/\(meetingB.uuidString)?time=42.0"
        ))
        await fix.core.handleDeepLink(url)

        await viewModel.applyPendingJumpIfNeeded()

        // VM for meeting A should not be affected
        #expect(viewModel.selectedTab == .notes)
        #expect(fakePlayer.currentTime == 0)
        // The jump should NOT have been consumed (it's for meeting B)
        #expect(fix.core.pendingTranscriptJump != nil)
    }

    @Test("jump arriving before audio loads is deferred then applied")
    @MainActor
    func deferredJumpAppliedAfterAudioLoad() async throws {
        let fix = try makeCoreFixture(testName: "DeepLinkJumpTests")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Deferred Jump"
        )

        let fakePlayer = DeepLinkFakePlayer()
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { fakePlayer }
        )

        // Set up a pending jump BEFORE load (no audio yet)
        let url = try #require(URL(
            string: "biscotti://meeting/\(meetingID.uuidString)?time=30.0"
        ))
        await fix.core.handleDeepLink(url)

        // Apply jump -- audio not loaded, so seek should be deferred
        await viewModel.applyPendingJumpIfNeeded()

        #expect(viewModel.selectedTab == .transcript)
        // Player has no audio, so currentTime stays 0
        #expect(fakePlayer.currentTime == 0)
        // Jump was consumed (tab switch happened)
        #expect(fix.core.pendingTranscriptJump == nil)

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

    @Test("consumeTranscriptJump is called after applying jump")
    @MainActor
    func consumeCalledAfterApply() async throws {
        let fix = try makeCoreFixture(testName: "DeepLinkJumpTests")
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

        // Set up jump
        let url = try #require(URL(
            string: "biscotti://meeting/\(meetingID.uuidString)?time=50.0"
        ))
        await fix.core.handleDeepLink(url)
        #expect(fix.core.pendingTranscriptJump != nil)

        // Apply
        await viewModel.applyPendingJumpIfNeeded()

        // Consumed
        #expect(fix.core.pendingTranscriptJump == nil)
        #expect(fakePlayer.currentTime == 50.0)
    }

    @Test("no pending jump is a no-op")
    @MainActor
    func noPendingJumpIsNoOp() async throws {
        let fix = try makeCoreFixture(testName: "DeepLinkJumpTests")
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

        // No jump set
        await viewModel.applyPendingJumpIfNeeded()

        // Nothing changed
        #expect(viewModel.selectedTab == .notes)
        #expect(fakePlayer.currentTime == 0)
    }
}
