import Foundation
import Testing
@testable import TranscriptionService

@Suite("DownloadPhaseGate")
struct DownloadPhaseGateTests {
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

        // Wait for the delay to expire.
        try await Task.sleep(for: .milliseconds(150))

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

        // Wait for the delay to expire.
        try await Task.sleep(for: .milliseconds(150))

        #expect(message == "second")
        #expect(gate.hasElapsed == true)
    }
}
