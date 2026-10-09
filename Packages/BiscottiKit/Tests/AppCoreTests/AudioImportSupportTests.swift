import BiscottiTestSupport
import Foundation
import Testing
@testable import AppCore

@Suite("AudioImportSupport")
@MainActor
struct AudioImportSupportTests {
    @Test("audio and video extensions are supported, others are not")
    func extensionFiltering() {
        let base = URL(fileURLWithPath: "/nonexistent")
        for ext in ["mp3", "m4a", "wav", "aiff", "aac", "flac", "mp4", "mov", "m4v"] {
            let url = base.appendingPathComponent("file.\(ext)")
            #expect(AudioImportSupport.isSupported(url), "expected .\(ext) supported")
        }
        for ext in ["txt", "pdf", "png", "zip", "csv", ""] {
            let url = base.appendingPathComponent("file.\(ext)")
            #expect(!AudioImportSupport.isSupported(url), "expected .\(ext) rejected")
        }
    }

    @Test("directories and non-file URLs are rejected")
    func directoriesAndRemote() throws {
        let dir = try makeTempAudioSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!AudioImportSupport.isSupported(dir))
        #expect(try !AudioImportSupport.isSupported(#require(URL(string: "https://example.com/a.mp3"))))
    }

    @Test("the open panel filter includes audio and movie")
    func panelTypes() {
        let types = AudioImportSupport.allowedContentTypes
        #expect(types.contains(.audio))
        #expect(types.contains(.movie))
        #expect(types.contains(.mp3))
        #expect(types.contains(.wav))
    }

    @Test("alert copy: single file and batch")
    func alertCopy() throws {
        #expect(AudioImportAlert(failures: []) == nil)
        let one = try #require(AudioImportAlert(failures: [
            AudioImportFailure(fileName: "a.mp3", message: "Broken.")
        ]))
        #expect(one.title == "Couldn\u{2019}t import a.mp3")
        #expect(one.message == "Broken.")
        let two = try #require(AudioImportAlert(failures: [
            AudioImportFailure(fileName: "a.mp3", message: "Broken."),
            AudioImportFailure(fileName: "b.wav", message: "Empty.")
        ]))
        #expect(two.title == "Couldn\u{2019}t import 2 files")
        #expect(two.message == "a.mp3: Broken.\nb.wav: Empty.")
    }

    @Test("a second batch started mid-import is queued onto the first")
    func reentrantBatchQueues() async throws {
        let fix = try makeCoreFixture(testName: "ImportQueue")
        defer { fix.cleanup() }
        let dir = try makeTempAudioSourceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try writeSilentWAV(named: "first.wav", in: dir)
        let second = try writeSilentWAV(named: "second.wav", in: dir)

        async let one: Void = fix.core.importAudioFiles(at: [first])
        // Runs while the first batch is suspended inside the importer.
        await Task.yield()
        async let two: Void = fix.core.importAudioFiles(at: [second])
        _ = await (one, two)
        await fix.core.awaitPendingTranscription()

        #expect(Set(fix.core.summaries.map(\.title)) == ["first", "second"])
        #expect(!fix.core.isImportingAudio)
    }
}
