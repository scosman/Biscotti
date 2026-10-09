import BiscottiTestSupport
import Foundation
import Testing
import TranscriptionService
@testable import AppCore
@testable import AppShellUI

/// Counts open-panel presentations and replays canned selections.
@MainActor
private final class PanelStub {
    var selections: [[URL]]
    private(set) var presentCount = 0

    init(_ selections: [[URL]]) {
        self.selections = selections
    }

    func present() -> [URL] {
        presentCount += 1
        return selections.isEmpty ? [] : selections.removeFirst()
    }
}

@Suite("AppShellViewModel -- audio file import")
@MainActor
struct AppShellAudioImportTests {
    private func makeViewModel(
        _ fix: CoreFixture, panel: PanelStub
    ) -> AppShellViewModel {
        AppShellViewModel(core: fix.core, presentAudioOpenPanel: { panel.present() })
    }

    @Test("a picked file is imported, selected and transcribed")
    func pickedFileImports() async throws {
        let fix = try makeCoreFixture(testName: "ShellImportPick")
        defer { fix.cleanup() }
        let dir = try makeTempAudioSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try writeSilentWAV(named: "Standup.wav", in: dir)
        let panel = PanelStub([[wav]])
        let viewModel = makeViewModel(fix, panel: panel)

        await viewModel.importAudioFiles()
        await fix.core.awaitPendingTranscription()

        #expect(panel.presentCount == 1)
        #expect(fix.core.summaries.map(\.title) == ["Standup"])
        #expect(fix.core.meetingsSelection == Set(fix.core.summaries.map(\.id)))
        #expect(fix.fakeEngine.backing.processAudioCalled)
        #expect(viewModel.audioImportAlert == nil)
    }

    @Test("cancelling the panel imports nothing")
    func cancelDoesNothing() async throws {
        let fix = try makeCoreFixture(testName: "ShellImportCancel")
        defer { fix.cleanup() }
        let panel = PanelStub([[]])
        let viewModel = makeViewModel(fix, panel: panel)

        await viewModel.importAudioFiles()

        #expect(panel.presentCount == 1)
        #expect(fix.core.summaries.isEmpty)
        #expect(fix.core.audioImportFailures.isEmpty)
        #expect(viewModel.audioImportAlert == nil)
        #expect(!fix.fakeEngine.backing.processAudioCalled)
    }

    @Test("a failing file exposes a Couldn't import alert, then dismisses")
    func failureIsExposed() async throws {
        let fix = try makeCoreFixture(testName: "ShellImportFail")
        defer { fix.cleanup() }
        let dir = try makeTempAudioSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("notes.mp3")
        try Data("this is definitely not audio".utf8).write(to: fake)
        let viewModel = makeViewModel(fix, panel: PanelStub([[fake]]))

        await viewModel.importAudioFiles()

        let alert = try #require(viewModel.audioImportAlert)
        #expect(alert.title == "Couldn\u{2019}t import notes.mp3")
        #expect(!alert.message.isEmpty)
        #expect(fix.core.summaries.isEmpty)

        viewModel.dismissAudioImportAlert()
        #expect(viewModel.audioImportAlert == nil)
    }

    @Test("several picked files import one after another, all transcribed")
    func multipleFilesSequential() async throws {
        let fix = try makeCoreFixture(testName: "ShellImportMany")
        defer { fix.cleanup() }
        let dir = try makeTempAudioSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try writeSilentWAV(named: "one.wav", in: dir)
        let second = try writeSilentWAV(named: "two.wav", in: dir)
        let viewModel = makeViewModel(fix, panel: PanelStub([[first, second]]))

        await viewModel.importAudioFiles()
        await fix.core.awaitPendingTranscription()

        #expect(Set(fix.core.summaries.map(\.title)) == ["one", "two"])
        // The single in-flight guard must not have failed the second job.
        for summary in fix.core.summaries {
            #expect(fix.core.transcription.jobs[summary.id] == .completed)
        }
        #expect(viewModel.audioImportAlert == nil)
    }

    @Test("a dropped non-audio file is rejected, reported, and creates no meeting")
    func droppedNonAudioRejected() async throws {
        let fix = try makeCoreFixture(testName: "ShellDropReject")
        defer { fix.cleanup() }
        let dir = try makeTempAudioSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = dir.appendingPathComponent("readme.txt")
        try Data("hello".utf8).write(to: text)
        let viewModel = makeViewModel(fix, panel: PanelStub([]))

        #expect(!viewModel.canAcceptDrop([text]))
        await viewModel.importDroppedFiles([text])

        #expect(fix.core.summaries.isEmpty)
        let alert = try #require(viewModel.audioImportAlert)
        #expect(alert.title == "Couldn\u{2019}t import readme.txt")
        #expect(alert.message == AudioImportSupport.unsupportedMessage)
        #expect(!fix.fakeEngine.backing.processAudioCalled)
    }

    @Test("a mixed drop is accepted, imports the audio and reports the rest")
    func mixedDrop() async throws {
        let fix = try makeCoreFixture(testName: "ShellDropMixed")
        defer { fix.cleanup() }
        let dir = try makeTempAudioSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try writeSilentWAV(named: "good.wav", in: dir)
        let text = dir.appendingPathComponent("readme.txt")
        try Data("hello".utf8).write(to: text)
        let viewModel = makeViewModel(fix, panel: PanelStub([]))

        #expect(viewModel.canAcceptDrop([text, wav]))
        await viewModel.importDroppedFiles([text, wav])
        await fix.core.awaitPendingTranscription()

        #expect(fix.core.summaries.map(\.title) == ["good"])
        #expect(viewModel.audioImportAlert?.title == "Couldn\u{2019}t import readme.txt")
    }

    @Test("a drop of several bad files lists each in one alert")
    func multipleFailuresOneAlert() async throws {
        let fix = try makeCoreFixture(testName: "ShellDropMany")
        defer { fix.cleanup() }
        let dir = try makeTempAudioSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("a.txt")
        let second = dir.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: first)
        try Data("b".utf8).write(to: second)
        let viewModel = makeViewModel(fix, panel: PanelStub([]))

        await viewModel.importDroppedFiles([first, second])

        let alert = try #require(viewModel.audioImportAlert)
        #expect(alert.title == "Couldn\u{2019}t import 2 files")
        #expect(alert.message.contains("a.txt"))
        #expect(alert.message.contains("b.txt"))
    }
}
