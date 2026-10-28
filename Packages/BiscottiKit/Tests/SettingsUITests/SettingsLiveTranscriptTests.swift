import AppCore
import BiscottiTestSupport
import DataStore
import Foundation
import LiveTranscriptionService
import Testing
@testable import SettingsUI
@testable import TranscriptionService

@Suite("SettingsViewModel -- live transcript")
@MainActor
struct SettingsLiveTranscriptTests {
    private static let eightGiB: UInt64 = 8 << 30
    private static let sixteenGiB: UInt64 = 16 << 30

    @Test("The toggle writes the setting and posts the change")
    func liveTranscriptToggleWritesSettingAndPostsNotification() async throws {
        let fix = try makeCoreFixture(testName: "SettingsLiveTranscript")
        defer { fix.cleanup() }
        let viewModel = SettingsViewModel(core: fix.core, physicalMemory: Self.sixteenGiB)
        await viewModel.load()
        #expect(viewModel.liveTranscriptEnabled)

        let posts = PostCount()
        let token = NotificationCenter.default.addObserver(
            forName: .liveTranscriptEnabledDidChange, object: nil, queue: .main
        ) { _ in posts.increment() }
        defer { NotificationCenter.default.removeObserver(token) }

        await viewModel.setLiveTranscriptEnabled(false)
        #expect(!viewModel.liveTranscriptEnabled)
        #expect(try await fix.store.settings().liveTranscriptEnabled == false)
        #expect(posts.value == 1)

        await viewModel.setLiveTranscriptEnabled(true)
        #expect(try await fix.store.settings().liveTranscriptEnabled == true)
        #expect(posts.value == 2)
    }

    @Test("The toggle shows the resolved default: off on an 8 GiB Mac, on above it, a choice wins")
    func toggleShowsResolvedDefault() async throws {
        let fix = try makeCoreFixture(testName: "SettingsLiveTranscript")
        defer { fix.cleanup() }
        let small = SettingsViewModel(core: fix.core, physicalMemory: Self.eightGiB)
        #expect(!small.liveTranscriptEnabled, "before load, too")
        await small.load()
        #expect(!small.liveTranscriptEnabled)
        let large = SettingsViewModel(core: fix.core, physicalMemory: Self.sixteenGiB)
        await large.load()
        #expect(large.liveTranscriptEnabled)

        try await fix.store.updateSettings { $0.liveTranscriptEnabled = true }
        await small.load()
        #expect(small.liveTranscriptEnabled)
    }

    @Test("Settings says the live transcript is being prepared while its model loads and the toggle is on")
    func preparingCaptionShowsWhileLiveIsOn() async throws {
        let fix = try makeCoreFixture(testName: "SettingsLiveTranscript")
        defer { fix.cleanup() }
        let liveOn = SettingsViewModel(core: fix.core, physicalMemory: Self.sixteenGiB)
        let liveOff = SettingsViewModel(core: fix.core, physicalMemory: Self.eightGiB)
        await liveOn.load()
        await liveOff.load()
        #expect(!liveOn.isPreparingLiveTranscript)

        fix.core.transcription.modelsBeingPrepared = [LiveTranscriptionDefaults.whisperModel]
        #expect(liveOn.isPreparingLiveTranscript)
        #expect(!liveOff.isPreparingLiveTranscript, "no caption under a toggle that is off")
        fix.core.transcription.modelsBeingPrepared = ["openai_whisper-large-v3-v20240930_626MB"]
        #expect(!liveOn.isPreparingLiveTranscript, "the final pass's model alone is not the live transcript")
        fix.core.transcription.modelsBeingPrepared = []
    }

    @Test("Settings warns while the startup disk is low, read when it opens")
    func lowDiskWarningShowsWhileTheDiskIsLow() async throws {
        let low = try makeCoreFixture(hardwareDiskBytes: 10_000_000_000, testName: "SettingsLowDisk")
        defer { low.cleanup() }
        let warned = SettingsViewModel(core: low.core)
        #expect(!warned.isLowOnDiskSpace, "not read before Settings opens")
        await warned.load()
        #expect(warned.isLowOnDiskSpace)
        #expect(SettingsViewModel.lowDiskWarning.contains("low on disk space"))

        let roomy = try makeCoreFixture(hardwareDiskBytes: 80_000_000_000, testName: "SettingsLowDisk")
        defer { roomy.cleanup() }
        let clear = SettingsViewModel(core: roomy.core)
        await clear.load()
        #expect(!clear.isLowOnDiskSpace)
    }

    @Test("Settings offers the live model's download and shows when it is on disk")
    func liveModelDownloadUpdatesState() async throws {
        let model = FakeLiveModel(present: false)
        let live = makeFakeLiveService(model: model)
        let fix = try makeCoreFixture(liveTranscription: live, testName: "SettingsLiveTranscript")
        defer { fix.cleanup() }
        let viewModel = SettingsViewModel(core: fix.core)
        #expect(viewModel.liveModelState == .missing)
        #expect(SettingsView.liveModelCaption(for: .missing).contains("MB"))

        await viewModel.downloadLiveModel()
        #expect(viewModel.liveModelState == .ready)
        #expect(model.downloadCount == 1)
    }
}

private final class PostCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
