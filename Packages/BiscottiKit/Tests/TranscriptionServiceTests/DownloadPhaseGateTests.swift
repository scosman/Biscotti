import Foundation
import Testing
@testable import TranscriptionService

@Suite("DownloadPhaseGate")
struct DownloadPhaseGateTests {
    /// Polls a condition with short sleeps until it becomes true, failing
    /// if the timeout is exceeded. Uses a generous budget (5 s) so that
    /// loaded CI runners don't race against tiny margins.
    @MainActor
    private func awaitCondition(
        timeout: Duration = .seconds(5),
        pollInterval: Duration = .milliseconds(10),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            #expect(ContinuousClock.now < deadline, "Timed out waiting for condition")
            if ContinuousClock.now >= deadline { return }
            try await Task.sleep(for: pollInterval)
        }
    }

    @Test("cancel before delay elapses prevents callback")
    @MainActor
    func cancelPreventsCallback() async throws {
        let gate = DownloadPhaseGate(delay: .seconds(10))
        var callbackFired = false

        gate.start { callbackFired = true }
        // Cancel immediately -- well before the 10s delay.
        gate.cancel()

        // Give a brief moment for any stray Task to fire.
        try await Task.sleep(for: .milliseconds(50))

        #expect(callbackFired == false)
        #expect(gate.hasElapsed == false)
    }

    @Test("hasElapsed is false before delay")
    @MainActor
    func hasElapsedFalseBeforeDelay() {
        let gate = DownloadPhaseGate(delay: .seconds(10))
        #expect(gate.hasElapsed == false)
    }

    @Test("hasElapsed becomes true after delay")
    @MainActor
    func hasElapsedTrueAfterDelay() async throws {
        let gate = DownloadPhaseGate(delay: .milliseconds(50))
        var callbackFired = false

        gate.start { callbackFired = true }

        // Poll until the gate fires; generous timeout absorbs CI load.
        try await awaitCondition { callbackFired && gate.hasElapsed }

        #expect(callbackFired == true)
        #expect(gate.hasElapsed == true)
    }

    @Test("multiple start calls before cancel are all suppressed")
    @MainActor
    func multipleStartsCancelled() async throws {
        let gate = DownloadPhaseGate(delay: .seconds(10))
        var callCount = 0

        gate.start { callCount += 1 }
        gate.start { callCount += 1 }

        gate.cancel()

        try await Task.sleep(for: .milliseconds(50))
        #expect(callCount == 0) // cancelled before either could fire
    }

    @Test("latest callback wins when delay fires")
    @MainActor
    func latestCallbackWins() async throws {
        let gate = DownloadPhaseGate(delay: .milliseconds(50))
        var message = ""

        gate.start { message = "first" }
        gate.start { message = "second" } // replaces the pending callback

        // Poll until the gate fires; generous timeout absorbs CI load.
        try await awaitCondition { gate.hasElapsed }

        #expect(message == "second")
        #expect(gate.hasElapsed == true)
    }
}
