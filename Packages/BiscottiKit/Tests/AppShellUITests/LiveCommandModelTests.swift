import AppCore
import BiscottiTestSupport
import Foundation
import LiveTranscriptionService
import Testing
@testable import AppShellUI

@Suite("LiveCommandModel")
@MainActor
struct LiveCommandModelTests {
    private func fixture(isEnabled: Bool = true, modelPresent: Bool = true) throws -> (CoreFixture, LiveTranscriptionService) {
        let live = makeFakeLiveService(
            model: FakeLiveModel(present: modelPresent),
            isEnabled: isEnabled,
            timing: LiveTiming(publishInterval: .zero, stopDeadline: .milliseconds(200), pumpInterval: .milliseconds(5), finishMargin: .milliseconds(50))
        )
        return try (makeCoreFixture(liveTranscription: live, testName: "LiveCommandModel"), live)
    }

    @Test("The title reads Hide while the recording screen shows the open drawer, else Show")
    func titleFlipsWithDrawerState() async throws {
        let (fix, live) = try fixture()
        let model = LiveCommandModel(core: fix.core)
        live.isDrawerExpanded = true
        #expect(model.title == "Show Live Transcript", "nothing is recording")
        #expect(LiveCommandModel().title == "Show Live Transcript")

        await fix.core.startRecording()
        #expect(fix.core.route == .recording)
        #expect(model.title == "Hide Live Transcript")
        live.isDrawerExpanded = false
        #expect(model.title == "Show Live Transcript")
        live.isDrawerExpanded = true
        fix.core.showSettings()
        #expect(model.title == "Show Live Transcript", "the recording screen is not shown")
        await stop(fix)
    }

    @Test("Enabled whenever the toggle shows: a recording with live transcription on, available or not")
    func enabledWhileTheToggleShows() async throws {
        #expect(!LiveCommandModel().isEnabled, "no core yet")

        let (fix, live) = try fixture()
        let model = LiveCommandModel(core: fix.core)
        #expect(!model.isEnabled, "not recording")
        await fix.core.startRecording()
        #expect(live.status == .starting)
        #expect(model.isEnabled)
        await live.setEnabled(false)
        #expect(!model.isEnabled, "live transcription off")
        await stop(fix)

        let (missing, missingLive) = try fixture(modelPresent: false)
        let unavailable = LiveCommandModel(core: missing.core)
        await missing.core.startRecording()
        #expect(missingLive.status == .unavailable(.modelMissing))
        #expect(unavailable.isEnabled, "the drawer offers the download")
        unavailable.toggle()
        #expect(missingLive.isDrawerExpanded)
        await stop(missing)
    }

    @Test("On the recording screen the command shows and hides the drawer")
    func toggleFlipsTheDrawer() async throws {
        let (fix, live) = try fixture()
        let model = LiveCommandModel(core: fix.core)
        model.toggle()
        #expect(!live.isDrawerExpanded, "disabled while not recording")
        await fix.core.startRecording()
        model.toggle()
        #expect(live.isDrawerExpanded)
        model.toggle()
        #expect(!live.isDrawerExpanded)
        await stop(fix)
    }

    @Test("On another screen the command brings the recording screen forward with the drawer shown")
    func toggleOnAnotherScreenShowsTheRecording() async throws {
        let (fix, live) = try fixture()
        let model = LiveCommandModel(core: fix.core)
        let windowShown = ShowCount()
        model.showMainWindow = { windowShown.count += 1 }
        await fix.core.startRecording()
        live.isDrawerExpanded = true
        fix.core.showSettings()

        model.toggle()
        #expect(fix.core.route == .recording)
        #expect(live.isDrawerExpanded, "shown, not flipped to hidden")
        #expect(windowShown.count == 1)
        await stop(fix)
    }

    private func stop(_ fix: CoreFixture) async {
        _ = await fix.core.stopRecording()
        await fix.core.awaitPendingTranscription()
        fix.cleanup()
    }
}

@MainActor
private final class ShowCount {
    var count = 0
}
