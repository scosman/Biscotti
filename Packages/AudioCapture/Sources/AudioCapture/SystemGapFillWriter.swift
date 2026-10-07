import AudioToolbox
import Foundation
import os

private let logger = Logger(subsystem: "net.scosman.biscotti.audiocapture", category: "SystemGapFill")

/// Fills reconnect gaps with silence on the system track's writer thread.
///
/// Tracks host-clock timing between audio buffers and writes silence
/// to an `ExtAudioFile` for any gap exceeding the jitter threshold
/// (100 ms). Used by `LiveSystemCaptureEngine`; tested independently
/// via `SystemGapFillTests`.
///
/// **Thread-safety:** `@unchecked Sendable` — all calls must come from
/// a single thread (the writer thread). Owned by `LiveSystemCaptureEngine`
/// which serializes access.
final class SystemGapFillWriter: @unchecked Sendable {
    /// Host-clock nanoseconds when the next sample is expected.
    /// Zero until the first buffer is processed.
    private(set) var expectedNextHostNanos: UInt64 = 0

    /// Pre-allocated silence buffer reused across gap fills.
    /// Created lazily on the first gap fill; subsequent fills reuse it.
    private var silenceBuffer: [Float] = []

    /// Chunk size for gap-fill silence writes (frames per write call).
    static let chunkFrames = 8192

    /// Checks for a gap before this buffer and fills it with silence.
    /// Updates internal tracking afterward. Silence is NOT fed to the
    /// permission checker and write errors are NOT recorded as session
    /// write errors — only logged.
    ///
    /// - Parameters:
    ///   - hostTimeNanos: host-clock nanoseconds of this buffer
    ///     (from `AudioConvertHostTimeToNanos`).
    ///   - bufferFrameCount: number of frames in this buffer (at the
    ///     tap's native rate, not a resampled count).
    ///   - channelCount: channel count of this buffer.
    ///   - sampleRate: the tap's sample rate (Hz). Silence is written
    ///     at this rate (the ExtAudioFile client format).
    ///   - file: ExtAudioFile to write silence into.
    /// - Returns: number of silence frames written (0 if no gap).
    @discardableResult
    func processBuffer(
        hostTimeNanos: UInt64,
        bufferFrameCount: UInt32,
        channelCount: UInt32,
        sampleRate: Double,
        file: ExtAudioFileRef
    ) -> Int {
        var filledFrames = 0

        if expectedNextHostNanos > 0, hostTimeNanos > 0 {
            filledFrames = writeSilenceForGap(
                expected: expectedNextHostNanos,
                actual: hostTimeNanos,
                channelCount: channelCount,
                sampleRate: sampleRate,
                file: file
            )
        }

        // Update expected-next from THIS buffer's host time + duration.
        // Done before the caller writes the real buffer so a failed write
        // does not cause re-insertion on the next call.
        if hostTimeNanos > 0 {
            let durationNanos = UInt64(
                Double(bufferFrameCount) / sampleRate * 1_000_000_000
            )
            expectedNextHostNanos = hostTimeNanos + durationNanos
        }

        return filledFrames
    }

    /// Resets tracking for a new session. Not needed across reconnects
    /// (tracking persists to detect the reconnect gap).
    func reset() {
        expectedNextHostNanos = 0
    }

    // MARK: - Silence writing

    private func writeSilenceForGap(
        expected: UInt64,
        actual: UInt64,
        channelCount: UInt32,
        sampleRate: Double,
        file: ExtAudioFileRef
    ) -> Int {
        var framesRemaining = gapSilenceFrameCount(
            expectedNextHostNanos: expected,
            actualHostNanos: actual,
            sampleRate: sampleRate
        )
        guard framesRemaining > 0 else { return 0 }

        let totalFrames = framesRemaining
        let gapSeconds = Double(actual - expected) / 1_000_000_000
        logger.notice(
            "System gap fill: \(gapSeconds, privacy: .public)s (\(totalFrames, privacy: .public) frames)"
        )

        let channels = Int(max(channelCount, 1))
        let chunk = Self.chunkFrames
        ensureSilenceCapacity(channels: channels, chunkFrames: chunk)

        silenceBuffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while framesRemaining > 0 {
                let count = min(chunk, framesRemaining)
                let buffer = AudioBuffer(
                    mNumberChannels: channelCount,
                    mDataByteSize: UInt32(count * channels * MemoryLayout<Float>.size),
                    mData: base
                )
                var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
                let status = ExtAudioFileWrite(file, UInt32(count), &bufferList)
                if status != noErr {
                    logger.error(
                        "System gap-fill write failed: \(status, privacy: .public) — aborting fill"
                    )
                    return
                }
                framesRemaining -= count
            }
        }

        return totalFrames
    }

    /// Ensures the pre-allocated silence buffer is large enough for
    /// `chunkFrames * channels` floats.
    private func ensureSilenceCapacity(channels: Int, chunkFrames: Int) {
        let needed = chunkFrames * channels
        if silenceBuffer.count < needed {
            silenceBuffer = [Float](repeating: 0, count: needed)
        }
    }
}
