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
