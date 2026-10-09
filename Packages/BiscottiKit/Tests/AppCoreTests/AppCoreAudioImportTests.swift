import AppCore
import BiscottiTestSupport
import Foundation
import Recording
import Testing
@testable import DataStore

@Suite("AppCore -- audio file import")
@MainActor
struct AppCoreAudioImportTests {
    // MARK: - Success

    @Test("a valid WAV becomes a meeting with one mic ref and is transcribed mic-only")
    func validFileImports() async throws {
        let fix = try makeCoreFixture(testName: "AudioImportValid")
        defer { fix.cleanup() }
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.writeWAV(named: "Standup notes.wav", in: dir)

        let meetingID = try await Self.unwrap(fix.core.importAudioFile(at: source))
        await fix.core.awaitPendingTranscription()

        // Listed and selected.
        #expect(fix.core.summaries.map(\.id) == [meetingID])
        #expect(fix.core.meetingsSelection == [meetingID])

        // Title from filename, duration recorded, audio present.
        let detail = try #require(try await fix.store.meetingDetail(id: meetingID))
        #expect(detail.title == "Standup notes")
        #expect(detail.hasAudio)
        let duration = try #require(detail.recordingDuration)
        #expect(abs(duration - 0.5) < 0.05)

        // One present .mic ref inside <Recordings>/<uuid>/ with the original extension.
        let refs = try await fix.store.storedAudioFileRefs(meetingID: meetingID)
        let mic = try #require(refs.mic)
        #expect(refs.system == nil)
        #expect(refs.present)
        let expectedDir = fix.core.recording.meetingDirectory(for: meetingID)
        #expect(mic == expectedDir.appendingPathComponent("imported.wav"))
        #expect(FileManager.default.fileExists(atPath: mic.path))
        let size = try #require(
            try FileManager.default.attributesOfItem(atPath: mic.path)[.size] as? Int64
        )
        #expect(try size == Int64(Data(contentsOf: source).count))

        // Marker removed.
        let marker = expectedDir.appendingPathComponent(RecordingController.markerFileName)
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        // Original untouched; transcriber ran on the mic file only.
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(fix.fakeEngine.backing.processAudioCalled)
        #expect(fix.fakeEngine.backing.lastMicURL == mic)
        #expect(fix.fakeEngine.backing.lastSystemURL == nil)
    }

    @Test("start date is the file's creation date")
    func startDateFromFile() async throws {
        let fix = try makeCoreFixture(testName: "AudioImportDate")
        defer { fix.cleanup() }
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.writeWAV(named: "old.wav", in: dir)
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: source.path)

        let meetingID = try await Self.unwrap(fix.core.importAudioFile(at: source))
        await fix.core.awaitPendingTranscription()

        let detail = try #require(try await fix.store.meetingDetail(id: meetingID))
        #expect(abs(detail.date.timeIntervalSince(created)) < 1)
    }

    @Test("importing while recording leaves runState untouched")
    func importDuringRecording() async throws {
        let fix = try makeCoreFixture(testName: "AudioImportWhileRecording")
        defer { fix.cleanup() }
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.writeWAV(named: "side.wav", in: dir)

        await fix.core.startRecording()
        let recordingState = fix.core.runState
        let route = fix.core.route
        guard case .recording = recordingState else {
            Issue.record("expected recording, got \(recordingState)")
            return
        }

        _ = try await Self.unwrap(fix.core.importAudioFile(at: source))
        await fix.core.awaitPendingTranscription()

        #expect(fix.core.runState == recordingState)
        #expect(fix.core.route == route)
        #expect(fix.core.recording.state.isRecording)
    }

    // MARK: - Validation failures (nothing created)

    @Test("a text file renamed .mp3 is rejected and creates nothing")
    func fakeMP3Rejected() async throws {
        let fix = try makeCoreFixture(testName: "AudioImportFake")
        defer { fix.cleanup() }
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("notes.mp3")
        try Data("this is definitely not audio".utf8).write(to: source)

        let result = await fix.core.importAudioFile(at: source)

        guard case let .failure(error) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(error == .noAudioTrack || error == .unreadable)
        try await Self.expectNothingCreated(fix)
    }

    @Test("an empty file is rejected and creates nothing")
    func emptyFileRejected() async throws {
        let fix = try makeCoreFixture(testName: "AudioImportEmpty")
        defer { fix.cleanup() }
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("empty.wav")
        try Data().write(to: source)

        let result = await fix.core.importAudioFile(at: source)

        #expect(result == .failure(.emptyAudio))
        try await Self.expectNothingCreated(fix)
    }

    @Test("a missing file is unreadable and creates nothing")
    func missingFileRejected() async throws {
        let fix = try makeCoreFixture(testName: "AudioImportMissing")
        defer { fix.cleanup() }
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).wav")

        let result = await fix.core.importAudioFile(at: missing)

        #expect(result == .failure(.unreadable))
        try await Self.expectNothingCreated(fix)
    }

    @Test("a WAV with zero frames is rejected and creates nothing")
    func zeroDurationRejected() async throws {
        let fix = try makeCoreFixture(testName: "AudioImportZeroFrames")
        defer { fix.cleanup() }
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.writeWAV(named: "zero.wav", in: dir, frames: 0)

        let result = await fix.core.importAudioFile(at: source)

        guard case let .failure(error) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(error == .emptyAudio || error == .unreadable || error == .noAudioTrack)
        try await Self.expectNothingCreated(fix)
    }

    // MARK: - Rollback

    @Test("a copy failure removes the meeting row and the directory")
    func copyFailureRollsBack() async throws {
        let fix = try makeCoreFixture(testName: "AudioImportCopyFail")
        defer { fix.cleanup() }
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.writeWAV(named: "ok.wav", in: dir)
        let failingImporter = AudioFileImporter { _, destination in
            // Leave a partial file behind, then fail.
            try Data("partial".utf8).write(to: destination)
            throw CocoaError(.fileWriteOutOfSpace)
        }

        let result = await fix.core.importAudioFile(at: source, importer: failingImporter)

        guard case let .failure(error) = result, case .copyFailed = error else {
            Issue.record("expected .copyFailed, got \(result)")
            return
        }
        try await Self.expectNothingCreated(fix)
        #expect(!fix.fakeEngine.backing.processAudioCalled)
    }

    @Test("every error has a user-facing description")
    func errorDescriptions() {
        let errors: [AudioImportError] = [
            .unreadable, .noAudioTrack, .emptyAudio, .copyFailed("x"), .storageFailed("y")
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    // MARK: - Helpers

    private static func unwrap(
        _ result: Result<UUID, AudioImportError>
    ) throws -> UUID {
        switch result {
        case let .success(id): return id
        case let .failure(error):
            throw error
        }
    }

    private static func expectNothingCreated(_ fix: CoreFixture) async throws {
        #expect(try await fix.store.meetingSummaries().isEmpty)
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: fix.storageRoot.path
        )
        #expect(contents.isEmpty)
    }

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioImportSrc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a minimal 16-bit mono 8 kHz PCM WAV of silence (0.5 s by default).
    private static func writeWAV(
        named name: String, in dir: URL, frames: Int = 4000
    ) throws -> URL {
        let sampleRate: UInt32 = 8000
        let dataSize = UInt32(frames * 2)
        var data = Data()
        func append32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append32(36 + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append32(16)
        append16(1) // PCM
        append16(1) // mono
        append32(sampleRate)
        append32(sampleRate * 2)
        append16(2)
        append16(16)
        data.append(contentsOf: Array("data".utf8))
        append32(dataSize)
        data.append(Data(count: Int(dataSize)))
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
