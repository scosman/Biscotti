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
