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

    @Test("a cancelled calling task still completes the import (the work is not cancellable)")
    func cancelledCallerStillImports() async throws {
        let fix = try makeCoreFixture(testName: "ImportCancelledCaller")
        defer { fix.cleanup() }
        let dir = try Helpers.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Helpers.writeWAV(named: "c.wav", in: dir)

        let task = Task { @MainActor in
            await fix.core.importAudioFile(at: source)
        }
        task.cancel()
        let meetingID = try await Helpers.unwrap(task.value)
        await fix.core.awaitPendingTranscription()

        let mic = try #require(try await fix.store.storedAudioFileRefs(meetingID: meetingID).mic)
        #expect(FileManager.default.fileExists(atPath: mic.path))
        #expect(try await fix.store.meetingSummaries().map(\.id) == [meetingID])
        #expect(try Self.markedDirectories(in: fix.storageRoot).isEmpty)
    }

    @Test("the audio ref and marker exist before the copy starts")
    func refAndMarkerPrecedeCopy() async throws {
        let fix = try makeCoreFixture(testName: "ImportRefBeforeCopy")
        defer { fix.cleanup() }
        let dir = try Helpers.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Helpers.writeWAV(named: "slow.wav", in: dir)
        let gate = CopyGate()
        let importer = AudioFileImporter { _, _ in
            gate.entered = true
            while !gate.released {
                usleep(2000)
            }
            throw CocoaError(.fileWriteOutOfSpace)
        }

        let task = Task { @MainActor in
            await fix.core.importAudioFile(at: source, importer: importer)
        }
        for _ in 0 ..< 500 where !gate.entered {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(gate.entered)

        // Mid-copy: a crash now would leave exactly this state.
        let summaries = try await fix.store.meetingSummaries()
        let meetingID = try #require(summaries.first?.id)
        let refs = try await fix.store.storedAudioFileRefs(meetingID: meetingID)
        #expect(refs.mic != nil)
        #expect(!refs.present)
        #expect(try Self.markedDirectories(in: fix.storageRoot).count == 1)

        gate.released = true
        _ = await task.value
        #expect(try await fix.store.meetingSummaries().isEmpty)
    }

    @Test("orphan recovery reconciles a crash mid-copy: the marker goes, the partial file counts as present")
    func recoverOrphansAfterInterruptedCopy() async throws {
        let fix = try makeCoreFixture(testName: "ImportCrashMidCopy")
        defer { fix.cleanup() }
        let dir = try Helpers.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Helpers.writeWAV(named: "crash.wav", in: dir)
        let (meetingID, destination) = try await Self.simulateInterruptedImport(fix, source: source)
        try Data("partial".utf8).write(to: destination)

        await fix.core.recording.recoverOrphans()

        let refs = try await fix.store.storedAudioFileRefs(meetingID: meetingID)
        #expect(refs.mic == destination)
        #expect(refs.present)
        #expect(try Self.markedDirectories(in: fix.storageRoot).isEmpty)
        #expect(try await fix.store.meetingExists(id: meetingID))
    }

    @Test("orphan recovery after a crash before the copy leaves a consistent audio-less meeting")
    func recoverOrphansAfterCrashBeforeCopy() async throws {
        let fix = try makeCoreFixture(testName: "ImportCrashBeforeCopy")
        defer { fix.cleanup() }
        let dir = try Helpers.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Helpers.writeWAV(named: "crash.wav", in: dir)
        let (meetingID, destination) = try await Self.simulateInterruptedImport(fix, source: source)

        await fix.core.recording.recoverOrphans()

        let refs = try await fix.store.storedAudioFileRefs(meetingID: meetingID)
        #expect(refs.mic == destination)
        #expect(!refs.present)
        #expect(try Self.markedDirectories(in: fix.storageRoot).isEmpty)
        #expect(try await fix.store.meetingDetail(id: meetingID)?.hasAudio == false)
    }

    /// Leaves the state `importAudioFile` has when the app dies right after
    /// the audio ref is attached and before the copy runs.
    private static func simulateInterruptedImport(
        _ fix: CoreFixture, source: URL
    ) async throws -> (UUID, URL) {
        let importer = AudioFileImporter()
        let meetingID = try await fix.store.createMeeting(title: "crash")
        let directory = fix.core.recording.meetingDirectory(for: meetingID)
        let destination = try importer.prepare(source: source, into: directory)
        try await fix.store.attachAudio(
            [AudioFileRef(role: .mic, path: destination.path, byteSize: 0, isPresent: false)],
            to: meetingID
        )
        return (meetingID, destination)
    }
}

/// Lets a test hold the importer's copy primitive open (which runs off the
/// main actor) while it inspects the store.
private final class CopyGate: @unchecked Sendable {
    var entered = false
    var released = false
}
