import XCTest

@testable import AudioLab

final class RMSMonitorTests: XCTestCase {
    func testRMSOfSilenceIsZero() {
        let samples: [Float] = [0.0, 0.0, 0.0, 0.0, 0.0]
        let rms = RMSMonitor.computeRMS(samples, count: samples.count)
        XCTAssertEqual(rms, 0.0, accuracy: 0.0001)
    }

    func testRMSOfConstantSignal() {
        // RMS of a constant signal c = |c|
        let samples: [Float] = [0.5, 0.5, 0.5, 0.5]
        let rms = RMSMonitor.computeRMS(samples, count: samples.count)
        XCTAssertEqual(rms, 0.5, accuracy: 0.0001)
    }

    func testRMSOfKnownSineApproximation() {
        // RMS of a sine wave with amplitude A = A / sqrt(2) ~ 0.7071
        // Using a simple set of values that approximate this
        let samples: [Float] = [1.0, -1.0, 1.0, -1.0]
        let rms = RMSMonitor.computeRMS(samples, count: samples.count)
        XCTAssertEqual(rms, 1.0, accuracy: 0.0001)
    }

    func testRMSOfEmptyBufferIsZero() {
        let samples: [Float] = []
        let rms = RMSMonitor.computeRMS(samples, count: 0)
        XCTAssertEqual(rms, 0.0, accuracy: 0.0001)
    }

    func testMonitorTracksConsecutiveZeroSeconds() {
        let monitor = RMSMonitor(windowDuration: 2.0)
        let silence: [Float] = [0.0, 0.0, 0.0, 0.0]

        monitor.processSamples(silence, count: silence.count, bufferDuration: 1.0)
        XCTAssertEqual(monitor.consecutiveZeroSeconds, 1.0, accuracy: 0.01)
        XCTAssertFalse(monitor.isSuspectedFailure)

        monitor.processSamples(silence, count: silence.count, bufferDuration: 1.5)
        XCTAssertEqual(monitor.consecutiveZeroSeconds, 2.5, accuracy: 0.01)
        XCTAssertTrue(monitor.isSuspectedFailure)
    }

    func testMonitorResetsOnNonZeroSignal() {
        let monitor = RMSMonitor(windowDuration: 2.0)
        let silence: [Float] = [0.0, 0.0, 0.0, 0.0]
        let signal: [Float] = [0.5, -0.5, 0.5, -0.5]

        monitor.processSamples(silence, count: silence.count, bufferDuration: 1.0)
        XCTAssertEqual(monitor.consecutiveZeroSeconds, 1.0, accuracy: 0.01)

        monitor.processSamples(signal, count: signal.count, bufferDuration: 0.5)
        XCTAssertEqual(monitor.consecutiveZeroSeconds, 0.0, accuracy: 0.01)
        XCTAssertFalse(monitor.isSuspectedFailure)
    }

    func testMonitorResetClearsState() {
        let monitor = RMSMonitor(windowDuration: 1.0)
        let silence: [Float] = [0.0, 0.0]

        monitor.processSamples(silence, count: silence.count, bufferDuration: 2.0)
        XCTAssertTrue(monitor.isSuspectedFailure)

        monitor.reset()
        XCTAssertEqual(monitor.consecutiveZeroSeconds, 0.0, accuracy: 0.01)
        XCTAssertFalse(monitor.isSuspectedFailure)
    }
}
