import AudioToolbox
import AVFoundation
import Foundation
import Testing
@testable import AudioCapture

/// `LiveSystemCaptureEngine`'s own start, reconnect and stop, with the Core
/// Audio tap replaced by `FakeTapHardware`. The writer thread, the format
/// converter and the AAC file are real; tap buffers enter the engine's ring
/// buffer the way the IOProc enqueues them.
@Suite("System reconnect recovery", .serialized)
struct SystemReconnectTests {
    /// One reconnect attempt fails, as a tap rebuild can while a Bluetooth
    /// device drops away. The recording must stay open so the next attempt
    /// really rebuilds the tap, and the audio after it must reach the file.
    @Test("A failed reconnect keeps the recording, and the next reconnect rebuilds the tap")
    func failedReconnectThenRecovery() async throws {
        let rig = ReconnectRig()
        defer { rig.dispose() }
        try await rig.engine.start(writingTo: rig.url)
        try rig.deliver(seconds: 1)

        rig.hardware.failNextCreates = 1
        await #expect(throws: CaptureError.self) { try await rig.engine.reconnect() }
        rig.hardware.rate = 44100
        try await rig.engine.reconnect()
        #expect(rig.hardware.createCount == 3, "start, the failed attempt and the rebuild must each create a tap")

        try rig.deliver(seconds: 1, afterGap: 0.5)
        await rig.engine.stop()

        let samples = try MicCaptureTestHelpers.decodedSamples(rig.url)
        rig.expectDuration(of: samples, 2.5, "1 s, a 0.5 s reconnect gap, 1 s")
        rig.expectTone(in: samples, from: 0.2, to: 0.8, label: "before the failure")
        rig.expectTone(in: samples, from: 1.8, to: 2.3, label: "after the rebuild")
    }

    /// Without the new tap's rate, its buffers would be read at the old one.
    /// A missing, zero, negative or non-finite rate must fail the attempt,
    /// so the recorder retries it, and must never reach the writer.
    @Test(
        "A tap without a usable rate fails the reconnect, and a retry with a usable rate recovers",
        arguments: [nil, 0, -48000, .nan, .infinity] as [Double?]
    )
    func unusableTapRateFailsReconnect(rate: Double?) async throws {
        let rig = ReconnectRig()
        defer { rig.dispose() }
        try await rig.engine.start(writingTo: rig.url)
        try rig.deliver(seconds: 1)

        rig.hardware.rate = rate
        await #expect(throws: CaptureError.self) { try await rig.engine.reconnect() }
        rig.hardware.rate = 24000
        try await rig.engine.reconnect()
        try rig.deliver(seconds: 1, afterGap: 0.5)
        await rig.engine.stop()

        let samples = try MicCaptureTestHelpers.decodedSamples(rig.url)
        rig.expectDuration(of: samples, 2.5, "1 s, a 0.5 s reconnect gap, 1 s")
        rig.expectTone(in: samples, from: 1.8, to: 2.3, label: "after the retry")
    }

    /// `start()` must refuse a tap without a usable rate, as it already
    /// refuses a failed query, and stay retryable.
    @Test("start() rejects a tap without a usable rate and can be retried")
    func startRejectsUnusableRate() async throws {
        let rig = ReconnectRig()
        defer { rig.dispose() }

        rig.hardware.rate = 0
        await #expect(throws: CaptureError.self) { try await rig.engine.start(writingTo: rig.url) }
        rig.hardware.rate = 48000
        try await rig.engine.start(writingTo: rig.url)
        try rig.deliver(seconds: 1)
        await rig.engine.stop()

        let samples = try MicCaptureTestHelpers.decodedSamples(rig.url)
        rig.expectDuration(of: samples, 1, "1 s")
    }

    /// Every attempt must rebuild the tap, none may return early as a false
    /// success, and `stop()` must still end the recording afterwards.
    @Test("Repeated reconnect failures keep retrying, and stop() still ends the recording")
    func repeatedFailuresKeepRetrying() async throws {
        let rig = ReconnectRig()
        defer { rig.dispose() }
        try await rig.engine.start(writingTo: rig.url)
        try rig.deliver(seconds: 1)

        rig.hardware.failNextCreates = 3
        for _ in 0 ..< 3 {
            await #expect(throws: CaptureError.self) { try await rig.engine.reconnect() }
        }
        #expect(rig.hardware.createCount == 4, "every failed attempt must try to create a tap")

        await rig.engine.stop()
        try await rig.engine.reconnect()
        #expect(rig.hardware.createCount == 4, "a reconnect after stop() must do nothing")

        let samples = try MicCaptureTestHelpers.decodedSamples(rig.url)
        rig.expectDuration(of: samples, 1, "the 1 s before the failures")
    }

    /// A `stop()` that lands in the reconnect's settle delay ends the
    /// recording; the reconnect must not build a tap afterwards.
    @Test("stop() during a reconnect's settle delay ends the recording without a rebuild")
    func stopDuringSettleDelay() async throws {
        let rig = ReconnectRig()
        defer { rig.dispose() }
        try await rig.engine.start(writingTo: rig.url)
        try rig.deliver(seconds: 1)

        let reconnect = Task { try await rig.engine.reconnect() }
        try await Task.sleep(for: .milliseconds(50))
        await rig.engine.stop()
        try? await reconnect.value
        #expect(rig.hardware.createCount == 1, "no tap may be created after stop()")

        let samples = try MicCaptureTestHelpers.decodedSamples(rig.url)
        rig.expectDuration(of: samples, 1, "the 1 s before stop()")
    }
}

// MARK: - Rig

/// An engine on `FakeTapHardware` writing a temporary file. `deliver`
/// enqueues a phase-continuous 400 Hz tone at the fake tap's current rate,
/// in 441-frame buffers with contiguous host times.
private final class ReconnectRig: @unchecked Sendable {
    static let fileRate = EncoderSettings.voice.sampleRate
    static let toneHz = 400.0

    let url: URL
    let hardware = FakeTapHardware()
    let engine: LiveSystemCaptureEngine
    private var hostNanos: UInt64 = 1_000_000_000
    private var phase = 0.0

    /// Creates the engine on the fake hardware; `start()` is up to the test.
    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("system-reconnect-\(UUID()).aac")
        engine = LiveSystemCaptureEngine(tapHardware: hardware.operations)
    }

    /// Enqueues `seconds` of tone starting `gap` seconds after the last
    /// buffer, as the IOProc of the current tap would.
    func deliver(seconds: Double, afterGap gap: Double = 0) throws {
        let ring = try #require(hardware.ring)
        let rate = try #require(hardware.rate)
        hostNanos += UInt64(gap * 1_000_000_000)
        let total = Int(seconds * rate)
        var sent = 0
        while sent < total {
            let count = min(441, total - sent)
            var samples = [Float](repeating: 0, count: count)
            for index in 0 ..< count {
                samples[index] = Float(0.3 * sin(phase))
                phase += 2 * Double.pi * Self.toneHz / rate
            }
            let enqueued = samples.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
                )
                return ring.enqueue(
                    bufferList: &list,
                    frameCount: UInt32(count),
                    hostTime: AudioConvertNanosToHostTime(hostNanos)
                )
            }
            #expect(enqueued, "The ring buffer refused a buffer")
            hostNanos += UInt64(Double(count) / rate * 1_000_000_000)
            sent += count
        }
    }

    /// Expects the decoded file to last `seconds`, within AAC padding.
    func expectDuration(of samples: [Float], _ seconds: Double, _ what: String) {
        let decoded = Double(samples.count) / Self.fileRate
        #expect(abs(decoded - seconds) < 0.15, "Decoded \(decoded)s vs \(seconds)s (\(what))")
    }

    /// Expects the clean tone in every 100 ms window from `start` to `end`
    /// seconds. Silence scores 0, so missing audio fails here too.
    func expectTone(in samples: [Float], from start: Double, to end: Double, label: String) {
        let window = Int(Self.fileRate / 10)
        let lower = min(Int(start * Self.fileRate), samples.count)
        let upper = min(Int(end * Self.fileRate), samples.count)
        #expect(upper - lower >= window, "No audio \(label): the decoded file is \(samples.count) frames")
        var worst = 1.0
        var offset = lower
        while offset + window <= upper {
            let ratio = MicCaptureTestHelpers.toneEnergyRatio(
                samples[offset ..< offset + window], toneHz: Self.toneHz, sampleRate: Self.fileRate
            )
            worst = min(worst, ratio)
            offset += window
        }
        #expect(worst > 0.9, "Worst 100 ms window \(label) has only \(worst) of its energy in the tone")
    }

    /// Ends any recording still open and deletes the file.
    func dispose() {
        engine.teardown()
        try? FileManager.default.removeItem(at: url)
    }
}
