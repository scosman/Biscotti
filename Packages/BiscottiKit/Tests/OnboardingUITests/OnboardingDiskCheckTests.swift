import BiscottiTestSupport
import Calendar
import DataStore
import Permissions
import Testing
@testable import OnboardingUI

@Suite("OnboardingViewModel -- Disk space check")
@MainActor
struct OnboardingDiskCheckTests {
    @Test("disk check surfaces warning when insufficient (from permissions)")
    func diskCheckFromPermissions() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }

        let lowDiskModel = OnboardingViewModel(
            core: fixture.core,
            availableDiskBytes: { 1_048_576 }
        )

        await lowDiskModel.advance() // welcome -> permissions
        await lowDiskModel.skip() // -> modelDownload (checkDiskSpace runs)

        #expect(lowDiskModel.hasSufficientDisk == false)
    }

    @Test("disk check surfaces warning when insufficient (from calendarSelection)")
    func diskCheckFromCalendarSelection() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .authorized
        )
        defer { fixture.cleanup() }

        let lowDiskModel = OnboardingViewModel(
            core: fixture.core,
            availableDiskBytes: { 1_048_576 }
        )

        await lowDiskModel.advance() // welcome -> permissions
        await lowDiskModel.requestCalendar()
        await lowDiskModel.advance() // -> calendarSelection
        await lowDiskModel.advance() // -> modelDownload (checkDiskSpace runs)

        #expect(lowDiskModel.hasSufficientDisk == false)
    }

    @Test("sufficient disk check passes")
    func diskCheckPasses() async throws {
        let fixture = try makeCoreFixture(
            calendarAuthStatus: .denied
        )
        defer { fixture.cleanup() }

        let okModel = OnboardingViewModel(
            core: fixture.core,
            availableDiskBytes: { 100_000_000_000 }
        )

        await okModel.advance() // welcome -> permissions
        await okModel.skip() // -> modelDownload

        #expect(okModel.hasSufficientDisk == true)
    }
}
