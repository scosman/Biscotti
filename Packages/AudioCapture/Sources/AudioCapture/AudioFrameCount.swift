/// Computes the number of audio frames in a buffer given its byte size
/// and channel count.
///
/// Core Audio interleaved PCM buffers store `Float` samples laid out as:
///
///     mDataByteSize = frameCount * channelCount * sizeof(Float)
///
/// Returns 0 if `channelCount` is 0 or `byteSize` is 0.
public func audioFrameCount(byteSize: UInt32, channelCount: UInt32) -> UInt32 {
    let channels = max(channelCount, 1)
    let bytesPerFrame = UInt32(MemoryLayout<Float>.size) * channels
    guard bytesPerFrame > 0 else { return 0 }
    return byteSize / bytesPerFrame
}

/// Computes the number of silent frames to prepend to the system track
/// for two-track alignment.
///
/// - Parameters:
///   - systemHostTimeNanos: host-clock nanoseconds of the system tap's
///     first delivered frame.
///   - micAnchorSeconds: host-clock seconds of the mic's first delivered
///     sample (the recording's t=0).
///   - systemStartWall: `CACurrentMediaTime()` when system capture started.
///     Used as a clock-agnostic upper bound (the gap can't exceed how long
///     the capture has been running + 1 s slack).
///   - currentWall: current `CACurrentMediaTime()` when this function
///     is called (writer thread).
///   - sampleRate: the tap's sample rate (Hz).
///   - maxLeadingSilenceSeconds: absolute backstop (default 3600 s).
///
/// Returns 0 if `micAnchorSeconds <= 0`, `systemHostTimeNanos == 0`,
/// or the gap is non-positive.
public func leadingSilenceFrameCount(
    systemHostTimeNanos: UInt64,
    micAnchorSeconds: Double,
    systemStartWall: Double,
    currentWall: Double,
    sampleRate: Double,
    maxLeadingSilenceSeconds: Double = 3600
) -> Int {
    guard systemHostTimeNanos != 0, micAnchorSeconds > 0, sampleRate > 0 else { return 0 }

    let sysSeconds = Double(systemHostTimeNanos) / 1_000_000_000
    let gap = sysSeconds - micAnchorSeconds
    guard gap > 0 else { return 0 }

    let wallBound = max(0, currentWall - systemStartWall) + 1.0
    let cappedSeconds = min(gap, wallBound, maxLeadingSilenceSeconds)
    return Int((cappedSeconds * sampleRate).rounded())
}

/// Computes the number of silent frames to insert when the mic stream
/// resumes after a gap (device reconnect, config-change rebuild, etc.).
///
/// - Parameters:
///   - expectedNextHostNanos: host-clock nanoseconds when the next
///     sample was expected (last buffer's host time + its duration).
///   - actualHostNanos: host-clock nanoseconds of the first buffer
///     after the gap.
///   - sampleRate: the file's processing sample rate (Hz).
///   - thresholdSeconds: positive gaps smaller than this are treated as
///     jitter and ignored (default 0.005 s = 5 ms).
///   - maxFillSeconds: absolute cap on a single silence fill (default
///     300 s). Prevents a bad timestamp from producing a huge file.
///
/// Returns 0 if the gap is non-positive, below the threshold, or any
/// input is invalid (zero host times, zero sample rate).
public func micGapSilenceFrameCount(
    expectedNextHostNanos: UInt64,
    actualHostNanos: UInt64,
    sampleRate: Double,
    thresholdSeconds: Double = 0.005,
    maxFillSeconds: Double = 300
) -> Int {
    guard expectedNextHostNanos > 0, actualHostNanos > 0, sampleRate > 0 else { return 0 }
    guard actualHostNanos > expectedNextHostNanos else { return 0 }

    // Integer subtraction first to avoid precision loss from dividing
    // two large UInt64 values independently and then subtracting.
    let gapNanos = actualHostNanos - expectedNextHostNanos
    let gap = Double(gapNanos) / 1_000_000_000
    guard gap >= thresholdSeconds else { return 0 }

    let capped = min(gap, maxFillSeconds)
    return Int((capped * sampleRate).rounded())
}
