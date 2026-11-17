import Foundation
import Testing
@testable import AudioCapture

/// `LiveSystemCaptureEngine` teardown when `reconnect()` and `stop()` tear
/// down at the same time. The race is in the writer-thread join, so no tap
/// is needed: the test runs a real writer thread and holds it as it finishes.
@Suite("System engine teardown")
struct SystemTeardownTests {
    /// `reconnect()` runs off its caller's actor, so `stop()` can run while a
    /// reconnect still waits for the writer to drain. The writer signals that
    /// it is done only once, so a second join would wait forever. Both
    /// teardowns must return, and `stop()`'s must not close the file before
    /// the writer has finished.
    @Test("stop() during a reconnect's writer join returns once the writer finishes")
    func stopDuringReconnectWriterJoin() throws {
        let engine = LiveSystemCaptureEngine()
        let writer = HeldWriter()
        // A check that throws must not leave the writer, and with it the
        // first teardown, blocked. An extra signal after the release below
        // is harmless.
        defer { writer.release.signal() }
        engine.writerWillFinish = writer.hold
        engine.startWriterThread()

        // reconnect()'s teardown: tells the writer to stop and joins it.
        let reconnectDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            engine.teardownHardware()
            reconnectDone.signal()
        }
        try #require(writer.finishing.wait(timeout: .now() + 5) == .success, "The writer never began to finish")

        // stop()'s teardown starts while the first teardown still waits. The
        // 0.5 s check starts only once this thread runs, so a slow thread
        // start cannot pass it. It does not prove that the thread reached the
        // lock: `Mutex` cannot report a waiter. A pause of 0.5 s between the
        // signal and `teardown()` would let the check pass without contention.
        let stopStarted = DispatchSemaphore(value: 0)
        let stopDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            stopStarted.signal()
            engine.teardown()
            stopDone.signal()
        }
        try #require(stopStarted.wait(timeout: .now() + 5) == .success, "stop()'s teardown thread never started")
        #expect(
            stopDone.wait(timeout: .now() + 0.5) == .timedOut,
            "stop()'s teardown returned while the writer could still write the file"
        )

        writer.release.signal()
        #expect(reconnectDone.wait(timeout: .now() + 5) == .success, "reconnect()'s teardown never returned")
        #expect(stopDone.wait(timeout: .now() + 5) == .success, "stop()'s teardown never returned")
    }
}

/// Holds the writer thread after its final drain, before it signals that it
/// is done, until the test releases it.
private final class HeldWriter: Sendable {
    let finishing = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func hold() {
        finishing.signal()
        release.wait()
    }
}
