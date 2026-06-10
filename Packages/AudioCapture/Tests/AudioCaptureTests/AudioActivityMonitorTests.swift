import CoreAudio
import Testing
@testable import AudioCapture

@Suite("AudioActivityMonitor")
struct AudioActivityMonitorTests {
    // MARK: - Helpers

    private func makeProcess(
        id: AudioObjectID,
        bundleID: String? = "com.test.app",
        pid: pid_t = 1,
        isRunningInput: Bool = false,
        isRunningOutput: Bool = false
    ) -> AudioProcess {
        AudioProcess(
            id: id, bundleID: bundleID, pid: pid,
            isRunningInput: isRunningInput, isRunningOutput: isRunningOutput
        )
    }

    /// Collects the next value from an AsyncStream, recording a test issue if
    /// it takes longer than `timeout`.
    ///
    /// Note: this checks the deadline *after* `iterator.next()` returns, so it
    /// relies on the Fake resolving values promptly. A true pre-emptive timeout
    /// would require capturing the `inout` iterator in a `@Sendable` task-group
    /// closure, which Swift concurrency disallows. If the source never yields,
    /// the test will hang rather than fail — this matches the pattern used by
    /// other test suites in this package (e.g. RouteChangeTests).
    private func nextValue<T>(
        from iterator: inout AsyncStream<T>.Iterator,
        timeout: Duration = .seconds(2)
    ) async throws -> T? {
        let deadline = ContinuousClock.now + timeout
        let value = await iterator.next()
        if ContinuousClock.now > deadline {
            Issue.record("nextValue timed out after \(timeout)")
            return nil
        }
        return value
    }

    // MARK: - Tests

    @Test("subscribing emits the current process list immediately")
    func initialSnapshot() async throws {
        let fake = FakeProcessActivitySource()
        let processes = [makeProcess(id: 1), makeProcess(id: 2)]
        fake.setProcesses(processes)

        let monitor = AudioActivityMonitor(source: fake)
        let stream = await monitor.activityStream()
        var iterator = stream.makeAsyncIterator()

        let snapshot = try await nextValue(from: &iterator)
        #expect(snapshot == processes)
    }

    @Test("adding/removing processes emits updated snapshot")
    func processListChange() async throws {
        let fake = FakeProcessActivitySource()
        let initial = [makeProcess(id: 1)]
        fake.setProcesses(initial)

        let monitor = AudioActivityMonitor(source: fake)
        let stream = await monitor.activityStream()
        var iterator = stream.makeAsyncIterator()
        try await fake.waitUntilReady()

        // Consume initial snapshot.
        _ = try await nextValue(from: &iterator)

        // Change process list and notify.
        let updated = [makeProcess(id: 1), makeProcess(id: 2)]
        fake.setProcesses(updated)
        fake.sendChange()

        let snapshot = try await nextValue(from: &iterator)
        #expect(snapshot == updated)
    }

    @Test("changing IO state of a process emits updated snapshot")
    func runningStateChange() async throws {
        let fake = FakeProcessActivitySource()
        let initial = [makeProcess(id: 1, isRunningInput: false, isRunningOutput: false)]
        fake.setProcesses(initial)

        let monitor = AudioActivityMonitor(source: fake)
        let stream = await monitor.activityStream()
        var iterator = stream.makeAsyncIterator()
        try await fake.waitUntilReady()

        // Consume initial snapshot.
        _ = try await nextValue(from: &iterator)

        // Same process, different running state.
        let updated = [makeProcess(id: 1, isRunningInput: true, isRunningOutput: true)]
        fake.setProcesses(updated)
        fake.sendChange()

        let snapshot = try await nextValue(from: &iterator)
        #expect(snapshot == updated)
        #expect(snapshot?.first?.isRunningInput == true)
        #expect(snapshot?.first?.isRunningOutput == true)
    }

    @Test("change notification with identical snapshot does not yield")
    func noEmissionWhenUnchanged() async throws {
        let fake = FakeProcessActivitySource()
        let processes = [makeProcess(id: 1)]
        fake.setProcesses(processes)

        let monitor = AudioActivityMonitor(source: fake)
        let stream = await monitor.activityStream()
        var iterator = stream.makeAsyncIterator()
        try await fake.waitUntilReady()

        // Consume initial snapshot.
        _ = try await nextValue(from: &iterator)

        // Send change but don't alter the process list.
        fake.sendChange()

        // Next change should be a real change, not the no-op above.
        let different = [makeProcess(id: 1), makeProcess(id: 3)]
        fake.setProcesses(different)
        fake.sendChange()

        let snapshot = try await nextValue(from: &iterator)
        #expect(snapshot == different)
    }

    @Test("two streams both receive the same events")
    func multipleConsumers() async throws {
        let fake = FakeProcessActivitySource()
        let initial = [makeProcess(id: 1)]
        fake.setProcesses(initial)

        let monitor = AudioActivityMonitor(source: fake)
        let stream1 = await monitor.activityStream()
        let stream2 = await monitor.activityStream()
        var iter1 = stream1.makeAsyncIterator()
        var iter2 = stream2.makeAsyncIterator()
        try await fake.waitUntilReady()

        // Both get initial snapshot.
        let snap1 = try await nextValue(from: &iter1)
        let snap2 = try await nextValue(from: &iter2)
        #expect(snap1 == initial)
        #expect(snap2 == initial)

        // Both get update.
        let updated = [makeProcess(id: 1), makeProcess(id: 2)]
        fake.setProcesses(updated)
        fake.sendChange()

        let upd1 = try await nextValue(from: &iter1)
        let upd2 = try await nextValue(from: &iter2)
        #expect(upd1 == updated)
        #expect(upd2 == updated)
    }

    @Test("fake finish causes stream to end")
    func streamFinishes() async throws {
        let fake = FakeProcessActivitySource()
        fake.setProcesses([makeProcess(id: 1)])

        let monitor = AudioActivityMonitor(source: fake)
        let stream = await monitor.activityStream()
        var iterator = stream.makeAsyncIterator()
        try await fake.waitUntilReady()

        // Consume initial snapshot.
        _ = try await nextValue(from: &iterator)

        // Finish the fake.
        fake.finish()

        // Stream should end — next value is nil.
        let finalValue = await iterator.next()
        #expect(finalValue == nil)
    }
}
