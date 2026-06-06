import Testing
@testable import AudioCapture

@Suite("RMSMonitor")
struct RMSMonitorTests {
    @Test("RMS of silence is zero")
    func rmsOfSilence() {
        let rms = RMSMonitor.computeRMS([0.0, 0.0, 0.0, 0.0, 0.0])
        #expect(rms == 0.0)
    }

    @Test("RMS of constant signal equals that constant")
    func rmsOfConstantSignal() {
        let rms = RMSMonitor.computeRMS([0.5, 0.5, 0.5, 0.5])
        #expect(abs(rms - 0.5) < 0.0001)
    }

    @Test("RMS of alternating +1/-1 equals 1")
    func rmsOfAlternatingSignal() {
        let rms = RMSMonitor.computeRMS([1.0, -1.0, 1.0, -1.0])
        #expect(abs(rms - 1.0) < 0.0001)
    }

    @Test("RMS of empty buffer is zero")
    func rmsOfEmptyBuffer() {
        let rms = RMSMonitor.computeRMS([])
        #expect(rms == 0.0)
    }

    @Test("tracks consecutive zero seconds")
    func consecutiveZeroTracking() {
        var monitor = RMSMonitor(windowDuration: 2.0)
        let silence: [Float] = [0.0, 0.0, 0.0, 0.0]

        monitor.ingest(silence, bufferDuration: 1.0)
        #expect(!monitor.isSuspectedFailure)

        monitor.ingest(silence, bufferDuration: 1.5)
        #expect(monitor.isSuspectedFailure)
    }

    @Test("resets on non-zero signal")
    func resetsOnSignal() {
        var monitor = RMSMonitor(windowDuration: 2.0)
        let silence: [Float] = [0.0, 0.0, 0.0, 0.0]
        let signal: [Float] = [0.5, -0.5, 0.5, -0.5]

        monitor.ingest(silence, bufferDuration: 1.0)
        monitor.ingest(signal, bufferDuration: 0.5)
        #expect(!monitor.isSuspectedFailure)
    }

    @Test("reset clears state")
    func resetClearsState() {
        var monitor = RMSMonitor(windowDuration: 1.0)
        let silence: [Float] = [0.0, 0.0]

        monitor.ingest(silence, bufferDuration: 2.0)
        #expect(monitor.isSuspectedFailure)

        monitor.reset()
        #expect(!monitor.isSuspectedFailure)
    }

    @Test("not a failure below window duration")
    func notFailureBelowWindow() {
        var monitor = RMSMonitor(windowDuration: 5.0)
        let silence: [Float] = [0.0, 0.0, 0.0]

        monitor.ingest(silence, bufferDuration: 4.9)
        #expect(!monitor.isSuspectedFailure)
    }

    @Test("exactly at window duration triggers failure")
    func exactlyAtWindow() {
        var monitor = RMSMonitor(windowDuration: 3.0)
        let silence: [Float] = [0.0]

        monitor.ingest(silence, bufferDuration: 3.0)
        #expect(monitor.isSuspectedFailure)
    }
}
