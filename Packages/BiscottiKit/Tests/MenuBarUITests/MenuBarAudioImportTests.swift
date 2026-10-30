import BiscottiTestSupport
import Foundation
import Testing
@testable import AppCore
@testable import MenuBarUI

@Suite("MenuBarViewModel -- audio file import")
@MainActor
struct MenuBarAudioImportTests {
    @Test("a picked file opens the window and is imported")
    func pickedFileImports() async throws {
        let fix = try makeCoreFixture(testName: "MenuBarImportPick")
        defer { fix.cleanup() }
        let dir = try makeTempAudioSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try writeSilentWAV(named: "Call.wav", in: dir)
        var opened = 0
        let viewModel = MenuBarViewModel(
            core: fix.core,
            windowOpener: { opened += 1 },
            presentAudioOpenPanel: { [wav] }
        )

        await viewModel.importAudioFiles()
        await fix.core.awaitPendingTranscription()

        #expect(opened == 1)
        #expect(fix.core.summaries.map(\.title) == ["Call"])
    }

    @Test("cancelling the panel imports nothing")
    func cancelDoesNothing() async throws {
        let fix = try makeCoreFixture(testName: "MenuBarImportCancel")
        defer { fix.cleanup() }
        let viewModel = MenuBarViewModel(
            core: fix.core,
            presentAudioOpenPanel: { [] }
        )

        await viewModel.importAudioFiles()

        #expect(fix.core.summaries.isEmpty)
        #expect(fix.core.audioImportFailures.isEmpty)
    }

    @Test("a failing file lands in the core's failure list")
    func failureIsExposed() async throws {
        let fix = try makeCoreFixture(testName: "MenuBarImportFail")
        defer { fix.cleanup() }
        let dir = try makeTempAudioSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("notes.mp3")
        try Data("not audio".utf8).write(to: fake)
        let viewModel = MenuBarViewModel(
            core: fix.core,
            presentAudioOpenPanel: { [fake] }
        )

        await viewModel.importAudioFiles()

        #expect(fix.core.audioImportFailures.map(\.fileName) == ["notes.mp3"])
        #expect(fix.core.summaries.isEmpty)
    }
}
