import BiscottiTestSupport
import DataStore
import Foundation
import Testing
@testable import MeetingDetailUI

// MARK: - Helpers

/// Polls a condition until true, up to `timeout` (default 2 s).
private func pollUntil(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
) async throws {
    let iterations = Int(timeout.components.seconds * 20
        + timeout.components.attoseconds / 50_000_000_000_000_000)
    for _ in 0 ..< max(iterations, 1) {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
}

// MARK: - DualFakePlayer

/// Fake player for dual-file playback tests. Reuses the same shape as
/// FakeAudioPlayer (Phase 8) but is file-local to avoid type conflicts.
private final class DualFakePlayer: AudioPlaybackProviding,
    @unchecked Sendable
{
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 120
    var loadedURLs: [URL] = []
    var loadShouldThrow = false
    var playCalls: Int = 0
    var pauseCalls: Int = 0

    func advanceTime(by interval: TimeInterval) {
        guard isPlaying else { return }
        currentTime += interval
        if currentTime >= duration {
            currentTime = duration
            isPlaying = false
        }
    }

    func play() {
        isPlaying = true
        playCalls += 1
    }

    func pause() {
        isPlaying = false
        pauseCalls += 1
    }

    func load(urls: [URL]) throws {
        if loadShouldThrow {
            throw NSError(
                domain: "DualFakePlayer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Load failed"]
            )
        }
        loadedURLs = urls
    }
}

// MARK: - Dual-file loading tests

@Suite("Dual-file playback -- loading")
struct DualFileLoadingTests {
    @Test("both mic and system URLs loaded when both files exist")
    @MainActor
    func bothFilesLoaded() async throws {
        let fix = try makeCoreFixture(testName: "DualLoad")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()

        let player = DualFakePlayer()
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { player }
        )
        await viewModel.load()

        #expect(player.loadedURLs.count == 2)
        #expect(player.loadedURLs.count == 2)
        #expect(viewModel.canPlay == true)
        #expect(viewModel.isAudioAvailable == true)
    }

    @Test("loaded URLs contain correct paths for mic and system")
    @MainActor
    func loadedURLsContainCorrectPaths() async throws {
        let fix = try makeCoreFixture(testName: "DualLoad")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()

        let player = DualFakePlayer()
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { player }
        )
        await viewModel.load()

        let filenames = player.loadedURLs.map(\.lastPathComponent)
        #expect(filenames.contains("mic.aac"))
        #expect(filenames.contains("system.aac"))
    }

    @Test("mic-only recording loads single URL and plays")
    @MainActor
    func micOnlyLoadsAndPlays() async throws {
        let fix = try makeCoreFixture(testName: "DualLoad")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Mic Only"
        )
        let micRef = AudioFileRef(
            role: .mic,
            path: "/tmp/test/mic.aac",
            byteSize: 1024,
            isPresent: true
        )
        try await fix.store.attachAudio([micRef], to: meetingID)

        let player = DualFakePlayer()
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { player }
        )
        await viewModel.load()

        #expect(player.loadedURLs.count == 1)
        #expect(player.loadedURLs.count == 1)
        #expect(viewModel.canPlay == true)
        #expect(viewModel.isAudioAvailable == true)

        viewModel.playPause()
        #expect(viewModel.isPlaying == true)
    }

    @Test("system-only recording loads single URL and plays")
    @MainActor
    func systemOnlyLoadsAndPlays() async throws {
        let fix = try makeCoreFixture(testName: "DualLoad")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "System Only"
        )
        let sysRef = AudioFileRef(
            role: .system,
            path: "/tmp/test/system.aac",
            byteSize: 2048,
            isPresent: true
        )
        try await fix.store.attachAudio([sysRef], to: meetingID)

        let player = DualFakePlayer()
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { player }
        )
        await viewModel.load()

        #expect(player.loadedURLs.count == 1)
        #expect(player.loadedURLs.count == 1)
        #expect(viewModel.canPlay == true)

        viewModel.playPause()
        #expect(viewModel.isPlaying == true)
    }

    @Test("no audio files means canPlay is false")
    @MainActor
    func noFilesCannotPlay() async throws {
        let fix = try makeCoreFixture(testName: "DualLoad")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "No Audio"
        )

        let player = DualFakePlayer()
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { player }
        )
        await viewModel.load()

        #expect(viewModel.canPlay == false)
        #expect(viewModel.isAudioAvailable == false)
        #expect(player.loadedURLs.isEmpty)
    }

    @Test("files not present on disk means canPlay is false")
    @MainActor
    func nonPresentFilesCannotPlay() async throws {
        let fix = try makeCoreFixture(testName: "DualLoad")
        defer { fix.cleanup() }

        let meetingID = try await fix.store.createMeeting(
            title: "Gone Audio"
        )
        let micRef = AudioFileRef(
            role: .mic, path: "/gone/mic.aac",
            byteSize: 0, isPresent: false
        )
        let sysRef = AudioFileRef(
            role: .system, path: "/gone/system.aac",
            byteSize: 0, isPresent: false
        )
        try await fix.store.attachAudio(
            [micRef, sysRef], to: meetingID
        )

        let player = DualFakePlayer()
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { player }
        )
        await viewModel.load()

        #expect(viewModel.canPlay == false)
        #expect(viewModel.isAudioAvailable == false)
    }
}

// MARK: - Dual-file playback control tests

@Suite("Dual-file playback -- controls")
struct DualFileControlTests {
    @Test("play triggers player play")
    @MainActor
    func playTriggersPlayer() async throws {
        let fix = try makeCoreFixture(testName: "DualCtrl")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()

        let player = DualFakePlayer()
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { player }
        )
        await viewModel.load()

        #expect(player.playCalls == 0)
        viewModel.playPause()
        #expect(player.playCalls == 1)
        #expect(viewModel.isPlaying == true)
    }

    @Test("pause triggers player pause")
    @MainActor
    func pauseTriggersPlayer() async throws {
        let fix = try makeCoreFixture(testName: "DualCtrl")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()

        let player = DualFakePlayer()
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { player }
        )
        await viewModel.load()

        viewModel.playPause() // play
        #expect(player.pauseCalls == 0)

        viewModel.playPause() // pause
        #expect(player.pauseCalls == 1)
        #expect(viewModel.isPlaying == false)
    }

    @Test("seek applies to combined player")
    @MainActor
    func seekApplies() async throws {
        let fix = try makeCoreFixture(testName: "DualCtrl")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()

        let player = DualFakePlayer()
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { player }
        )
        await viewModel.load()

        viewModel.seek(to: 45.0)
        #expect(player.currentTime == 45.0)
        #expect(viewModel.playbackCurrentTime == 45.0)
    }

    @Test("duration reports combined player duration")
    @MainActor
    func durationReportsCombined() async throws {
        let fix = try makeCoreFixture(testName: "DualCtrl")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()

        let player = DualFakePlayer()
        player.duration = 300
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { player }
        )
        await viewModel.load()

        #expect(viewModel.playbackDuration == 300)
    }

    @Test("duration uses model recordingDuration over dual player guess")
    @MainActor
    func durationModelWinsDual() async throws {
        let fix = try makeCoreFixture(testName: "DualModelDur")
        defer { fix.cleanup() }

        // Create a meeting with a known recordingDuration (1800s)
        let meetingID = try await fix.createMeetingWithAudio(
            recordingDuration: 1800
        )

        // Dual player reports a wrong combined duration (7200s)
        let player = DualFakePlayer()
        player.duration = 7200
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { player }
        )
        await viewModel.load()

        // Model value wins over the player's wrong guess
        #expect(viewModel.playbackDuration == 1800)

        // Start playback so the ticker fires
        viewModel.playPause()
        player.advanceTime(by: 3)

        try await pollUntil { viewModel.playbackCurrentTime == 3 }

        // Model value must still win after ticker
        #expect(viewModel.playbackDuration == 1800)

        viewModel.stopPlayback()
    }

    @Test("stopPlayback pauses player and stops ticker")
    @MainActor
    func stopPlaybackPauses() async throws {
        let fix = try makeCoreFixture(testName: "DualCtrl")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()

        let player = DualFakePlayer()
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { player }
        )
        await viewModel.load()

        viewModel.playPause()
        #expect(viewModel.isPlaying == true)

        viewModel.stopPlayback()
        #expect(viewModel.isPlaying == false)
        #expect(player.isPlaying == false)
        #expect(player.pauseCalls >= 1)
    }

    @Test("ticker updates combined current time while playing")
    @MainActor
    func tickerUpdatesCombinedTime() async throws {
        let fix = try makeCoreFixture(testName: "DualCtrl")
        defer { fix.cleanup() }

        let meetingID = try await fix.createMeetingWithAudio()

        let player = DualFakePlayer()
        player.duration = 120
        let viewModel = MeetingDetailViewModel(
            core: fix.core,
            meetingID: meetingID,
            makePlayer: { player }
        )
        await viewModel.load()

        viewModel.playPause()
        player.advanceTime(by: 15)

        try await pollUntil { viewModel.playbackCurrentTime == 15 }

        #expect(viewModel.playbackCurrentTime == 15)
        #expect(viewModel.isPlaying == true)
    }
}
