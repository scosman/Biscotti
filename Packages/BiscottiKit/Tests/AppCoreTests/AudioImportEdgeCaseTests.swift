import AppCore
import BiscottiTestSupport
import Foundation
import Recording
import Testing
@testable import DataStore

@Suite("AppCore -- audio import edge cases")
@MainActor
struct AudioImportEdgeCaseTests {
    private typealias Helpers = AppCoreAudioImportTests

    /// Directories under the storage root that still hold a `.recording` marker.
    private static func markedDirectories(in root: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter {
                FileManager.default.fileExists(
                    atPath: $0.appendingPathComponent(RecordingController.markerFileName).path
                )
            }
    }

    @Test("importing the same file twice creates two distinct meetings")
    func sameFileTwice() async throws {
        let fix = try makeCoreFixture(testName: "ImportTwice")
        defer { fix.cleanup() }
        let dir = try Helpers.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Helpers.writeWAV(named: "standup.wav", in: dir)

        let first = try await Helpers.unwrap(fix.core.importAudioFile(at: source))
        let second = try await Helpers.unwrap(fix.core.importAudioFile(at: source))
        await fix.core.awaitPendingTranscription()

        #expect(first != second)
        #expect(Set(fix.core.summaries.map(\.id)) == [first, second])
        let firstMic = try #require(try await fix.store.storedAudioFileRefs(meetingID: first).mic)
        let secondMic = try #require(try await fix.store.storedAudioFileRefs(meetingID: second).mic)
        #expect(firstMic != secondMic)
        #expect(FileManager.default.fileExists(atPath: firstMic.path))
        #expect(FileManager.default.fileExists(atPath: secondMic.path))
        #expect(fix.core.transcription.jobs[first] == .completed)
        #expect(fix.core.transcription.jobs[second] == .completed)
    }

    @Test("a file already inside the Recordings directory can be imported")
    func sourceInsideRecordingsDirectory() async throws {
        let fix = try makeCoreFixture(testName: "ImportFromLibrary")
        defer { fix.cleanup() }
        let dir = try Helpers.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = try Helpers.writeWAV(named: "lib.wav", in: dir)
        let firstID = try await Helpers.unwrap(fix.core.importAudioFile(at: original))
        let inLibrary = try #require(try await fix.store.storedAudioFileRefs(meetingID: firstID).mic)
        #expect(inLibrary.path.hasPrefix(fix.storageRoot.path))

        let copyID = try await Helpers.unwrap(fix.core.importAudioFile(at: inLibrary))
        await fix.core.awaitPendingTranscription()

        #expect(copyID != firstID)
        let copyMic = try #require(try await fix.store.storedAudioFileRefs(meetingID: copyID).mic)
        #expect(copyMic != inLibrary)
        #expect(copyMic.deletingLastPathComponent() == fix.core.recording.meetingDirectory(for: copyID))
        #expect(FileManager.default.fileExists(atPath: inLibrary.path))
        #expect(FileManager.default.fileExists(atPath: copyMic.path))
        #expect(try Self.markedDirectories(in: fix.storageRoot).isEmpty)
    }

    @Test("a failed copy leaves no marker or partial file, and orphan recovery finds nothing")
    func failedCopyLeavesNoOrphan() async throws {
        let fix = try makeCoreFixture(testName: "ImportNoOrphan")
        defer { fix.cleanup() }
        let dir = try Helpers.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Helpers.writeWAV(named: "ok.wav", in: dir)
        let failing = AudioFileImporter { _, destination in
            try Data("partial".utf8).write(to: destination)
            throw CocoaError(.fileWriteOutOfSpace)
        }

        let result = await fix.core.importAudioFile(at: source, importer: failing)
        guard case .failure = result else {
            Issue.record("expected failure")
            return
        }
        await fix.core.recording.recoverOrphans()

        #expect(try FileManager.default.contentsOfDirectory(atPath: fix.storageRoot.path).isEmpty)
        #expect(try await fix.store.meetingSummaries().isEmpty)
    }

    @Test("a cancelled calling task never leaves a half-imported meeting")
    func cancelledCallerStaysConsistent() async throws {
        let fix = try makeCoreFixture(testName: "ImportCancelledCaller")
        defer { fix.cleanup() }
        let dir = try Helpers.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Helpers.writeWAV(named: "c.wav", in: dir)

        let task = Task { @MainActor in
            await fix.core.importAudioFile(at: source)
        }
        task.cancel()
        _ = await task.value
        await fix.core.awaitPendingTranscription()
        await fix.core.recording.recoverOrphans()

        // Either nothing was created, or a complete meeting exists: never
        // a stray directory, marker, or row without its files.
        let summaries = try await fix.store.meetingSummaries()
        let directories = try FileManager.default.contentsOfDirectory(atPath: fix.storageRoot.path)
        #expect(directories.count == summaries.count)
        #expect(try Self.markedDirectories(in: fix.storageRoot).isEmpty)
        for summary in summaries {
            let mic = try #require(try await fix.store.storedAudioFileRefs(meetingID: summary.id).mic)
            #expect(FileManager.default.fileExists(atPath: mic.path))
        }
    }
}
