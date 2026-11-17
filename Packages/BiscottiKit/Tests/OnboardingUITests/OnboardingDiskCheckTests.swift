import BiscottiTestSupport
import Calendar
import DataStore
import Permissions
import Testing
@testable import OnboardingUI

@Suite("OnboardingViewModel -- Disk space check (via SpeechEngineManager)")
@MainActor
struct OnboardingDiskCheckTests {
    @Test("Whisper insufficient disk surfaces in transcription row state")
    func whisperInsufficientDisk() async throws {
        // Low disk: SpeechEngineManager's disk probe will report insufficient
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            hardwareDiskBytes: 1_048_576 // 1 MB -- well below Whisper threshold
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance() // welcome -> permissions
        await viewModel.skip() // -> modelDownload

        // Target is Whisper (default on macOS 15), but disk is insufficient
        #expect(viewModel.transcriptionRowState() == .insufficientDisk)
    }

    @Test("sufficient disk shows idle for Whisper")
    func sufficientDiskShowsIdle() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            hardwareDiskBytes: 100_000_000_000
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance() // welcome -> permissions
        await viewModel.skip() // -> modelDownload

        #expect(viewModel.transcriptionRowState() == .idle(sizeCaption: "626 MB"))
    }
}
