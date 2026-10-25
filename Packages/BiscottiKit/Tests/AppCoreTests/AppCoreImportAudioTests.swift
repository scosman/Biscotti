import AppCore
import BiscottiTestSupport
import Foundation
import Testing
import TranscriptionService
@testable import DataStore

/// Inspector stub: accepts anything except files named "bad.*".
private struct StubInspector: AudioImportInspecting {
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    func inspect(url: URL) async throws -> AudioImportInfo {
        if url.lastPathComponent.hasPrefix("bad") { throw AudioImportError.notAudio }
        return AudioImportInfo(duration: 90, date: date)
    }
}

@Suite("AppCore -- audio import")
@MainActor
struct AppCoreImportAudioTests {
    private static func makeAudioFile(named name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data("fake audio".utf8).write(to: url)
        return url
    }

    @Test("imports a file as a dated meeting, copies it, and transcribes it as a single file")
    func importHappyPath() async throws {
        let fix = try makeCoreFixture(audioInspector: StubInspector(), testName: "ImportAudio")
        defer { fix.cleanup() }
        let url = try Self.makeAudioFile(named: "standup.m4a")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = await fix.core.importAudio(urls: [url])
        await fix.core.awaitPendingTranscription()

        let meetingID = try #require(result.imported.first)
        #expect(result.failures.isEmpty)

        // Dated with the file's date (not now), duration from the media.
        let detail = try #require(await fix.store.meetingDetail(id: meetingID))
        #expect(detail.date == StubInspector().date)
        #expect(detail.endDate == StubInspector().date.addingTimeInterval(90))
        #expect(detail.recordingDuration == 90)
        #expect(detail.isImported)

        // The original is untouched; a copy lives in the meeting's folder.
        #expect(FileManager.default.fileExists(atPath: url.path))
        let paths = try #require(await fix.store.audioPaths(meetingID: meetingID))
        #expect(paths.system == nil)
        #expect(paths.mic.lastPathComponent == "imported.m4a")
        #expect(FileManager.default.fileExists(atPath: paths.mic.path))

        // The engine got the single file as `mic` and no system file.
        #expect(fix.fakeEngine.backing.processAudioCalled)
        #expect(fix.fakeEngine.backing.lastMicURL == paths.mic)
        #expect(fix.fakeEngine.backing.lastSystemURL == nil)
        #expect(fix.core.transcription.jobs[meetingID] == .completed)
    }

    @Test("a rejected file creates no meeting and is reported")
    func importRejectsNonAudio() async throws {
        let fix = try makeCoreFixture(audioInspector: StubInspector(), testName: "ImportAudioBad")
        defer { fix.cleanup() }
        let url = try Self.makeAudioFile(named: "bad.mp4")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = await fix.core.importAudio(urls: [url])

        #expect(result.imported.isEmpty)
        #expect(result.failures.map(\.fileName) == ["bad.mp4"])
        #expect(try await fix.store.meetingSummaries().isEmpty)
    }

    @Test("good files still import when another file in the batch fails")
    func importPartialBatch() async throws {
        let fix = try makeCoreFixture(audioInspector: StubInspector(), testName: "ImportAudioPartial")
        defer { fix.cleanup() }
        let good = try Self.makeAudioFile(named: "a.wav")
        let bad = try Self.makeAudioFile(named: "bad.mov")
        defer {
            try? FileManager.default.removeItem(at: good.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: bad.deletingLastPathComponent())
        }

        let result = await fix.core.importAudio(urls: [bad, good])
        await fix.core.awaitPendingTranscription()

        #expect(result.imported.count == 1)
        #expect(result.failures.count == 1)
    }

    @Test("meeting date is creation date, then modification date, then now")
    func effectiveDateFallbacks() {
        let creation = Date(timeIntervalSince1970: 100)
        let modification = Date(timeIntervalSince1970: 200)
        let now = Date(timeIntervalSince1970: 300)
        #expect(AudioImporter.effectiveDate(creation: creation, modification: modification, now: now) == creation)
        #expect(AudioImporter.effectiveDate(creation: nil, modification: modification, now: now) == modification)
        #expect(AudioImporter.effectiveDate(creation: nil, modification: nil, now: now) == now)
    }
}
