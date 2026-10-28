import BiscottiTestSupport
import DataStore
import Foundation
import Synchronization
import Testing
import Transcription
import TranscriptionService
import Vocabulary

/// Free space a test sets.
private final class FakeDisk: Sendable {
    private let bytes: Mutex<Int64?>

    init(_ bytes: Int64?) {
        self.bytes = Mutex(bytes)
    }

    func set(_ value: Int64?) {
        bytes.withLock { $0 = value }
    }

    var diskSpace: DiskSpace {
        DiskSpace { [self] in bytes.withLock { $0 } }
    }
}

/// Records whether the disk was read on the main thread.
private final class ReadThreadProbe: Sendable {
    private let onMain = Mutex<Bool?>(nil)

    func record() {
        onMain.withLock { $0 = Thread.isMainThread }
    }

    var readOnMain: Bool? {
        onMain.withLock { $0 }
    }
}

private let lowSpace: Int64 = 10_000_000_000
private let roomySpace: Int64 = 80_000_000_000

@Suite("Low disk space and slow model loads")
@MainActor
struct TranscriptionServiceDiskSpaceTests {
    @MainActor
    private struct Fixture {
        let service: TranscriptionService
        let store: DataStore
        let engine: FakeTranscriber
        let disk: FakeDisk

        init(freeBytes: Int64?, threshold: Duration = .milliseconds(50)) throws {
            store = try DataStore(storage: .inMemory)
            engine = FakeTranscriber()
            engine.backing.holdsPasses = true
            disk = FakeDisk(freeBytes)
            service = TranscriptionService(
                store: store,
                engine: engine,
                vocabulary: VocabularyService(store: store),
                diskSpace: disk.diskSpace,
                slowLoadThreshold: threshold
            )
        }

        func meeting() async throws -> UUID {
            let meetingID = try await store.createMeeting(title: "Meeting")
            try await store.attachAudio([
                AudioFileRef(role: .mic, path: "/tmp/disk/mic.aac", byteSize: 100, isPresent: true),
                AudioFileRef(role: .system, path: "/tmp/disk/system.aac", byteSize: 100, isPresent: true)
            ], to: meetingID)
            return meetingID
        }

        /// Starts a pass and waits until the engine runs it.
        func startPass() async throws -> (UUID, Task<Void, Never>) {
            let meetingID = try await meeting()
            let task = Task { await service.transcribe(meetingID: meetingID) }
            try await waitUntil("the pass") { engine.isHoldingPass && engine.backing.modelLoadHandler != nil }
            return (meetingID, task)
        }
    }

    @Test("The compile threshold is 15 s and the low-disk threshold 20 GB")
    func thresholds() {
        #expect(SlowModelLoad.compileThreshold == .seconds(15))
        #expect(DiskSpace.lowThreshold == 20_000_000_000)
    }

    @Test("A final pass's model load that runs past the threshold on a low disk says so until the load ends")
    func slowLoadOnALowDiskShowsUntilItEnds() async throws {
        let fix = try Fixture(freeBytes: lowSpace)
        let (meetingID, pass) = try await fix.startPass()

        fix.engine.backing.modelLoadHandler?(true)
        try await waitUntil("the slow-load status") { fix.service.slowModelLoadOnLowDisk == meetingID }
        #expect(fix.service.isLowOnDiskSpace)

        fix.engine.backing.modelLoadHandler?(false)
        try await waitUntil("the status to clear") { fix.service.slowModelLoadOnLowDisk == nil }
        fix.engine.finishPass()
        await pass.value
    }

    @Test("A slow load with room on the disk, or a quick load on a low disk, shows nothing")
    func slowLoadWithRoomOrQuickLoadShowsNothing() async throws {
        let roomy = try Fixture(freeBytes: roomySpace)
        let (_, roomyPass) = try await roomy.startPass()
        roomy.engine.backing.modelLoadHandler?(true)
        try await Task.sleep(for: .milliseconds(150))
        #expect(roomy.service.slowModelLoadOnLowDisk == nil)
        roomy.engine.finishPass()
        await roomyPass.value

        let quick = try Fixture(freeBytes: lowSpace, threshold: .milliseconds(100))
        let (_, quickPass) = try await quick.startPass()
        quick.engine.backing.modelLoadHandler?(true)
        quick.engine.backing.modelLoadHandler?(false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(quick.service.slowModelLoadOnLowDisk == nil)
        quick.engine.finishPass()
        await quickPass.value
    }

    @Test("The status clears when the pass ends, even if the load's end never arrived")
    func statusClearsWhenThePassEnds() async throws {
        let fix = try Fixture(freeBytes: lowSpace)
        let (meetingID, pass) = try await fix.startPass()
        fix.engine.backing.modelLoadHandler?(true)
        try await waitUntil("the slow-load status") { fix.service.slowModelLoadOnLowDisk == meetingID }

        fix.engine.finishPass()
        await pass.value
        #expect(fix.service.slowModelLoadOnLowDisk == nil)
    }

    @Test("Reading the disk again updates the low-space flag both ways")
    func refreshFollowsTheDisk() async throws {
        let fix = try Fixture(freeBytes: roomySpace)
        #expect(await !fix.service.refreshDiskSpace())
        fix.disk.set(lowSpace)
        #expect(await fix.service.refreshDiskSpace())
        #expect(fix.service.isLowOnDiskSpace)
        fix.disk.set(nil)
        #expect(await !fix.service.refreshDiskSpace(), "unknown space is not low")
    }

    @Test("The disk is read off the main thread")
    func diskIsReadOffTheMainThread() async throws {
        let probe = ReadThreadProbe()
        let store = try DataStore(storage: .inMemory)
        let service = TranscriptionService(
            store: store,
            engine: FakeTranscriber(),
            vocabulary: VocabularyService(store: store),
            diskSpace: DiskSpace {
                probe.record()
                return lowSpace
            }
        )

        #expect(await service.refreshDiskSpace())
        #expect(probe.readOnMain == false)
    }
}
