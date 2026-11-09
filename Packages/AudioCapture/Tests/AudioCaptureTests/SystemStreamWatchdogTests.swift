import Foundation
import Testing
@testable import AudioCapture

/// Pure-logic tests for the stall decision, plus recorder-level tests that
/// the watchdog drives the file-preserving system reconnect with a cooldown.
@Suite("SystemStreamWatchdogTests")
struct SystemStreamWatchdogTests {
    private static let second: UInt64 = 1_000_000_000
    private static let window = 3 * second
    private static let now = 100 * second

    private func health(buffer: UInt64, nonZero: UInt64) -> StreamHealth {
        StreamHealth(lastBufferHostNanos: buffer, lastNonZeroHostNanos: nonZero)
    }

    private func evaluate(
        system: StreamHealth,
        mic: StreamHealth,
        armedAt: UInt64 = 0
    ) -> SystemStreamWatchdog.Stall? {
        SystemStreamWatchdog.evaluate(
            system: system,
            mic: mic,
            armedAtNanos: armedAt,
            nowNanos: Self.now,
            stallWindowNanos: Self.window
        )
    }

    // MARK: - Decision logic

    @Test("Recent non-zero system audio is healthy")
    func recentNonZeroIsHealthy() {
        let recent = Self.now - Self.second
        let verdict = evaluate(
            system: health(buffer: recent, nonZero: recent),
            mic: health(buffer: recent, nonZero: recent)
        )
        #expect(verdict == nil)
    }

    @Test("No system buffers for the whole window while the mic is live is a stall")
    func noBuffersIsStall() {
        let old = Self.now - 10 * Self.second
        let recent = Self.now - Self.second
        let verdict = evaluate(
            system: health(buffer: old, nonZero: old),
            mic: health(buffer: recent, nonZero: recent)
        )
        #expect(verdict == .noBuffers)
    }

    @Test("Only zero-filled system buffers for the whole window is a stall")
    func allZeroIsStall() {
        let old = Self.now - 10 * Self.second
        let recent = Self.now - Self.second
        let verdict = evaluate(
            system: health(buffer: recent, nonZero: old),
            mic: health(buffer: recent, nonZero: recent)
        )
        #expect(verdict == .allZero)
    }

    @Test("A quiet mic never produces a stall (silence may be legitimate)")
    func quietMicIsNotAStall() {
        let old = Self.now - 10 * Self.second
        let recent = Self.now - Self.second
        let verdict = evaluate(
            system: health(buffer: old, nonZero: old),
            mic: health(buffer: recent, nonZero: old)
        )
        #expect(verdict == nil)
    }

    @Test("An engine that does not report health never produces a stall")
    func unknownMicHealthIsNotAStall() {
        let verdict = evaluate(system: .unknown, mic: .unknown)
        #expect(verdict == nil)
    }

    @Test("A freshly armed window is not judged until it has fully elapsed")
    func freshlyArmedIsNotAStall() {
        let old = Self.now - 10 * Self.second
        let recent = Self.now - Self.second
        let verdict = evaluate(
            system: health(buffer: old, nonZero: old),
            mic: health(buffer: recent, nonZero: recent),
            armedAt: Self.now - Self.second
        )
        #expect(verdict == nil)
    }

    @Test("The system stream is judged once the armed window has elapsed")
    func armedWindowElapsedIsJudged() {
        let old = Self.now - 10 * Self.second
        let recent = Self.now - Self.second
        let verdict = evaluate(
            system: health(buffer: old, nonZero: old),
            mic: health(buffer: recent, nonZero: recent),
            armedAt: Self.now - Self.window
        )
        #expect(verdict == .noBuffers)
    }

    // MARK: - Recorder integration

    private static let fast = SystemStreamWatchdog.Configuration(
        stallWindow: .milliseconds(200),
        pollInterval: .milliseconds(25),
        reconnectCooldown: .seconds(10)
    )

    @Test("Watchdog reconnects the system engine (file-preserving) when it stalls while the mic is live")
    func watchdogReconnectsStalledSystemStream() async throws {
        let ctx = try TestRecorderFactory.make(watchdog: Self.fast)
        defer { TestRecorderFactory.cleanup(ctx) }

        try await ctx.recorder.start(paths: ctx.paths)

        // Mic is audibly live; system delivered nothing since start.
        ctx.micEngine.simulateBuffer(audible: true)
        try await Task.sleep(for: .milliseconds(150))
        ctx.micEngine.simulateBuffer(audible: true)
        try await Task.sleep(for: .milliseconds(150))
        ctx.micEngine.simulateBuffer(audible: true)
        try await Task.sleep(for: .milliseconds(150))

        #expect(ctx.systemEngine.reconnectCount == 1)
        #expect(ctx.systemEngine.stopCount == 0, "stop() must NOT be called on stall (would erase file)")
        #expect(ctx.systemEngine.startCount == 1, "start() must NOT be called on stall (would erase file)")
        #expect(ctx.micEngine.reconnectCount == 0)

        // Still stalled after the reconnect, but inside the cooldown: no loop.
        ctx.micEngine.simulateBuffer(audible: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(ctx.systemEngine.reconnectCount == 1, "stall reconnects must respect the cooldown")

        let stream = await ctx.recorder.stateStream()
        for await state in stream {
            #expect(state.isRecording == true)
            break
        }
    }

    @Test("Watchdog stays quiet while system audio keeps flowing")
    func watchdogIgnoresHealthyStream() async throws {
        let ctx = try TestRecorderFactory.make(watchdog: Self.fast)
        defer { TestRecorderFactory.cleanup(ctx) }

        try await ctx.recorder.start(paths: ctx.paths)

        for _ in 0 ..< 5 {
            ctx.micEngine.simulateBuffer(audible: true)
            ctx.systemEngine.simulateBuffer(audible: true)
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(ctx.systemEngine.reconnectCount == 0)
    }

    @Test("Watchdog stays quiet when the mic is also silent (quiet room, not a stall)")
    func watchdogIgnoresQuietRoom() async throws {
        let ctx = try TestRecorderFactory.make(watchdog: Self.fast)
        defer { TestRecorderFactory.cleanup(ctx) }

        try await ctx.recorder.start(paths: ctx.paths)

        for _ in 0 ..< 5 {
            ctx.micEngine.simulateBuffer(audible: false)
            ctx.systemEngine.simulateBuffer(audible: false)
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(ctx.systemEngine.reconnectCount == 0)
    }

    @Test("Watchdog reconnects again once the cooldown has elapsed")
    func watchdogReconnectsAfterCooldown() async throws {
        let config = SystemStreamWatchdog.Configuration(
            stallWindow: .milliseconds(100),
            pollInterval: .milliseconds(25),
            reconnectCooldown: .milliseconds(400)
        )
        let ctx = try TestRecorderFactory.make(watchdog: config)
        defer { TestRecorderFactory.cleanup(ctx) }

        try await ctx.recorder.start(paths: ctx.paths)

        // Keep the mic live and the system silent for ~700 ms: the first
        // reconnect lands at ~100-125 ms, the second ~400 ms later once the
        // cooldown lapses, and a third could not land before ~900 ms.
        for _ in 0 ..< 14 {
            ctx.micEngine.simulateBuffer(audible: true)
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(ctx.systemEngine.reconnectCount == 2)
        #expect(ctx.systemEngine.startCount == 1)
    }

    @Test("Stall events from the device-change stream honour the cooldown")
    func stallEventHonoursCooldown() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }

        try await ctx.recorder.start(paths: ctx.paths)
        try await ctx.deviceChangeProvider.waitUntilReady()

        ctx.deviceChangeProvider.send(.systemStreamStalled)
        try await Task.sleep(for: .milliseconds(200))
        #expect(ctx.systemEngine.reconnectCount == 1)

        ctx.deviceChangeProvider.send(.systemStreamStalled)
        try await Task.sleep(for: .milliseconds(200))
        #expect(ctx.systemEngine.reconnectCount == 1, "second stall inside the cooldown is ignored")

        // A genuine route change is never subject to the stall cooldown.
        ctx.deviceChangeProvider.send(.outputChanged)
        try await Task.sleep(for: .milliseconds(200))
        #expect(ctx.systemEngine.reconnectCount == 2)
        #expect(ctx.systemEngine.stopCount == 0)
        #expect(ctx.systemEngine.startCount == 1)

        ctx.deviceChangeProvider.finish()
    }

    @Test("Stall event does nothing when not recording")
    func stallEventWhileNotRecording() async throws {
        let ctx = try TestRecorderFactory.make()
        defer { TestRecorderFactory.cleanup(ctx) }

        ctx.deviceChangeProvider.send(.systemStreamStalled)
        try await Task.sleep(for: .milliseconds(50))
        #expect(ctx.systemEngine.reconnectCount == 0)
    }
}
