import AudioToolbox
@preconcurrency import AVFoundation
import Foundation
import os
import Synchronization

private let logger = Logger(subsystem: "net.scosman.biscotti.audiocapture", category: "LiveMicCapture")

/// Owns one recording attempt's file, conversion state and first-buffer anchor.
/// Each installed tap carries an identity checked under the same lock as writing.
/// Invalidating a tap waits for an in-flight write; subsequent callbacks are dropped.
/// Audio callbacks only try the lock, so they never wait for lifecycle operations.
final class MicCaptureSession: @unchecked Sendable {
    private final class Tap: Sendable {}

    private let processingFormat: AVAudioFormat
    private let onFirstBuffer: (@Sendable (Double) -> Void)?
    private let lock = OSAllocatedUnfairLock()
    /// Lifecycle reads must not contend with the audio callback for the write lock.
    private let deliveredBuffer = Atomic<Bool>(false)

    // The remaining mutable state is protected by lock.
    private var file: ExtAudioFileRef?
    private var activeTap: Tap?
    private var didNotifyFirstBuffer = false
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?

    /// Host-clock nanoseconds when the next sample is expected: last
    /// written buffer's host time + its duration. Zero until the first
    /// buffer is written. Protected by `lock`.
    private var expectedNextHostNanos: UInt64 = 0

    /// Pre-allocated silence buffer reused across gap fills, sized at
    /// `gapFillChunkFrames`. Created lazily on the first gap fill (one
    /// allocation); subsequent fills reuse the same buffer. Protected
    /// by `lock`.
    private var silenceBuffer: AVAudioPCMBuffer?

    /// Chunk size for gap-fill silence writes (frames per write call).
    private static let gapFillChunkFrames: AVAudioFrameCount = 8192

    /// Opens a new file and captures this attempt's callback immutably. A later
    /// recorder retry cannot redirect an old tap to its own file or callback.
    init(url: URL, encoder: EncoderSettings, onFirstBuffer: (@Sendable (Double) -> Void)?) throws {
        processingFormat = encoder.processingFormat
        self.onFirstBuffer = onFirstBuffer
        file = try VPIOFileHelper.createExtAudioFile(
            url: url, encoder: encoder, processingFormat: processingFormat
        )
    }

    /// Whether the currently installed tap has received nonempty hardware audio.
    /// This signals hardware liveness (a buffer arrived from the tap), not that a
    /// buffer was successfully converted and written. MicEngine uses it to choose
    /// between a lightweight same-engine restart (pre-delivery) and a full rebuild
    /// (post-delivery) on configuration changes. `onFirstBuffer` is the separate
    /// signal that confirms startup to AudioRecorder.
    /// Replacing the tap resets this without resetting the session's first anchor.
    var hasDeliveredBuffer: Bool {
        deliveredBuffer.load(ordering: .acquiring)
    }

    /// Creates the callback installed on AVAudioEngine and retires the previous
    /// tap, including during a restart of the same engine. The file stays open.
    func makeTapHandler() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        let tap = Tap()
        lock.lock()
        activeTap = tap
        deliveredBuffer.store(false, ordering: .releasing)
        converter = nil
        converterSourceFormat = nil
        // Keep expectedNextHostNanos across tap replacements so gap
        // detection spans reconnects within the same session/file.
        lock.unlock()
        return { [self, tap] buffer, when in
            handleTap(buffer: buffer, when: when, tap: tap)
        }
    }

    /// Revokes the current tap before hardware teardown. Holding the write lock
    /// closes the check/write race even if a callback is already executing.
    func invalidateTap() {
        lock.lock()
        defer { lock.unlock() }
        activeTap = nil
        deliveredBuffer.store(false, ordering: .releasing)
        converter = nil
        converterSourceFormat = nil
    }

    /// Revokes all taps and finalizes this attempt's file. Idempotent, and
    /// safe even when a removed tap still retains its callback and this session.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        activeTap = nil
        deliveredBuffer.store(false, ordering: .releasing)
        if let file { ExtAudioFileDispose(file) }
        file = nil
        converter = nil
        converterSourceFormat = nil
    }

    /// Finalizes a session if startup failed before its owner could close it.
    deinit { close() }

    /// Converts and writes only for the active tap. Ownership validation, graph
    /// readiness updates and first-anchor selection are serialized with invalidation.
    private func handleTap(buffer: AVAudioPCMBuffer, when: AVAudioTime, tap: Tap) {
        guard buffer.frameLength > 0, lock.lockIfAvailable() else { return }
        let anchor = writeBufferIfCurrent(buffer, when: when, tap: tap)
        lock.unlock()
        // The immutable callback belongs to this session, even if close/retry
        // happens after unlocking. It can only signal the old attempt's stream.
        if let anchor { onFirstBuffer?(anchor) }
    }

    /// Requires lock. Returns an anchor only after the first successful write;
    /// rejected, empty, unconvertible or failed buffers cannot confirm startup.
    private func writeBufferIfCurrent(_ buffer: AVAudioPCMBuffer, when: AVAudioTime, tap: Tap) -> Double? {
        guard activeTap === tap, let file else { return nil }
        // Intentionally set before extraction/conversion/write: this signals
        // hardware liveness (selects the full-rebuild path in MicEngine),
        // not successful file output. onFirstBuffer confirms startup.
        deliveredBuffer.store(true, ordering: .releasing)
        guard let mono = VPIOBufferHelper.extractChannel0(buffer) else { return nil }
        let bufferToWrite: AVAudioPCMBuffer
        if mono.format.sampleRate == processingFormat.sampleRate {
            bufferToWrite = mono
        } else {
            guard let converter = converterForSource(mono.format),
                  let converted = VPIOBufferHelper.convert(mono, to: processingFormat, using: converter)
            else { return nil }
            bufferToWrite = converted
        }

        // Fill any gap since the last written buffer with silence so the
        // mic track stays aligned with wall-clock time after reconnects.
        let actualHostNanos: UInt64 = when.isHostTimeValid
            ? AudioConvertHostTimeToNanos(when.hostTime) : 0
        if expectedNextHostNanos > 0, actualHostNanos > 0 {
            fillGapWithSilence(
                expectedNextHostNanos: expectedNextHostNanos,
                actualHostNanos: actualHostNanos,
                file: file
            )
        }

        // Advance expected-next from the *input* tap buffer (not the
        // resampled output). The converter may hold back or emit extra
        // frames between calls, so `bufferToWrite.frameLength` does not
        // match the input's host-time span — using it would create
        // false positive gaps. Update before the write so silence is
        // not re-inserted if the write fails on the next call.
        if actualHostNanos > 0 {
            let durationNanos = UInt64(
                Double(buffer.frameLength) / Double(buffer.format.sampleRate) * 1_000_000_000
            )
            expectedNextHostNanos = actualHostNanos + durationNanos
        }

        guard VPIOBufferHelper.writeBuffer(bufferToWrite, to: file) == noErr else {
            return nil
        }

        guard !didNotifyFirstBuffer else { return nil }
        didNotifyFirstBuffer = true
        let anchor = actualHostNanos > 0
            ? Double(actualHostNanos) / 1_000_000_000
            : 0
        logger.notice("First mic buffer delivered -- anchor=\(anchor, privacy: .public)s")
        return anchor
    }

    /// Writes silence for the gap between the expected and actual host times.
    /// Requires `lock`. Uses the pre-allocated silence buffer, chunking large
    /// fills to avoid unbounded allocation on the audio callback path.
    private func fillGapWithSilence(
        expectedNextHostNanos: UInt64,
        actualHostNanos: UInt64,
        file: ExtAudioFileRef
    ) {
        var framesRemaining = gapSilenceFrameCount(
            expectedNextHostNanos: expectedNextHostNanos,
            actualHostNanos: actualHostNanos,
            sampleRate: processingFormat.sampleRate
        )
        guard framesRemaining > 0 else { return }

        let gapSeconds = Double(actualHostNanos - expectedNextHostNanos) / 1_000_000_000
        logger.notice("Mic gap fill: \(gapSeconds, privacy: .public)s (\(framesRemaining, privacy: .public) frames)")

        let chunk = Self.gapFillChunkFrames
        let buf = silenceBufferForFill()

        while framesRemaining > 0 {
            let count = AVAudioFrameCount(min(framesRemaining, Int(chunk)))
            buf.frameLength = count
            // Zero the buffer data for the active frame count.
            if let data = buf.floatChannelData?[0] {
                memset(data, 0, Int(count) * MemoryLayout<Float>.size)
            }
            if VPIOBufferHelper.writeBuffer(buf, to: file) != noErr {
                logger.error("Mic gap-fill write failed -- aborting fill")
                return
            }
            framesRemaining -= Int(count)
        }
    }

    /// Returns the pre-allocated silence buffer, creating it on first use.
    /// Requires `lock`.
    private func silenceBufferForFill() -> AVAudioPCMBuffer {
        if let silenceBuffer { return silenceBuffer }
        guard let buf = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: Self.gapFillChunkFrames
        ) else {
            preconditionFailure("Failed to allocate silence buffer for gap fill")
        }
        silenceBuffer = buf
        return buf
    }

    /// Reuses conversion state only within the active tap and matching format.
    /// Requires lock so invalidation cannot reset a converter while it is in use.
    private func converterForSource(_ sourceFormat: AVAudioFormat) -> AVAudioConverter? {
        if converterSourceFormat == sourceFormat, let converter { return converter }
        guard let converter = AVAudioConverter(from: sourceFormat, to: processingFormat) else {
            logger.error("Failed to build AVAudioConverter for mic resampling")
            return nil
        }
        self.converter = converter
        converterSourceFormat = sourceFormat
        return converter
    }
}
