import BiscottiTestSupport
import Calendar
import DataStore
import Intelligence
import Permissions
import Testing
@testable import OnboardingUI

@Suite("OnboardingViewModel -- Disk space click-time check")
@MainActor
struct OnboardingDiskCheckTests {
    @Test("transcription download with low disk sets diskWarning and does not start")
    func transcriptionLowDiskSetsWarning() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }
        fixture.fakeEngine.backing.modelsPresentResult = false

        // Set available disk well below the model size + 2 GB buffer
        let lowDiskModel = OnboardingViewModel(
            core: fixture.core,
            availableDiskBytes: { 1_048_576 } // 1 MB
        )

        await lowDiskModel.advance() // welcome -> permissions
        await lowDiskModel.skip() // -> modelDownload

        // Attempt download
        lowDiskModel.startTranscriptionDownload()

        // diskWarning should be set
        #expect(lowDiskModel.diskWarning != nil)
        #expect(lowDiskModel.diskWarning?.modelName == "Transcription & Speaker ID")
        // Download should NOT have started
        #expect(lowDiskModel.isDownloading == false)
        #expect(lowDiskModel.downloadComplete == false)
    }

    @Test("transcription download with sufficient disk proceeds normally")
    func transcriptionSufficientDiskProceeds() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }
        fixture.fakeEngine.backing.modelsPresentResult = false

        let okModel = OnboardingViewModel(
            core: fixture.core,
            availableDiskBytes: { 100_000_000_000 }
        )

        await okModel.advance() // welcome -> permissions
        await okModel.skip() // -> modelDownload

        okModel.startTranscriptionDownload()

        // Wait for the retained task to complete
        try await Task.sleep(for: .milliseconds(50))

        // No disk warning
        #expect(okModel.diskWarning == nil)
        // Download completed
        #expect(okModel.downloadComplete == true)
    }

    @Test("language download with low disk sets diskWarning and does not start")
    func languageLowDiskSetsWarning() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            hardwareDiskBytes: 1_000_000_000 // 1 GB — well below requirement
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        viewModel.startLanguageDownload()

        // Should set diskWarning
        #expect(viewModel.diskWarning != nil)

        // Wait to confirm no download started
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.modelManager.isModelAvailable == false)
    }

    @Test("language download with sufficient disk does not set diskWarning")
    func languageSufficientDiskProceeds() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied,
            hardwareDiskBytes: 100_000_000_000
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(core: fixture.core)
        await viewModel.advance()
        await viewModel.skip()

        viewModel.startLanguageDownload()

        #expect(viewModel.diskWarning == nil)
    }

    @Test("diskWarning cleared on resetForReplay")
    func diskWarningClearedOnReset() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }

        let viewModel = OnboardingViewModel(
            core: fixture.core,
            availableDiskBytes: { 1_048_576 }
        )
        await viewModel.advance()
        await viewModel.skip()

        viewModel.startTranscriptionDownload()
        #expect(viewModel.diskWarning != nil)

        viewModel.resetForReplay()
        #expect(viewModel.diskWarning == nil)
    }
}
