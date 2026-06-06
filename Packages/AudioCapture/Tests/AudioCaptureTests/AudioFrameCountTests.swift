import Testing
@testable import AudioCapture

@Suite("audioFrameCount")
struct AudioFrameCountTests {
    // MARK: - Mono (1 channel)

    @Test("mono standard buffer")
    func monoStandardBuffer() {
        // 1024 frames * 1 channel * 4 bytes = 4096 bytes
        #expect(audioFrameCount(byteSize: 4096, channelCount: 1) == 1024)
    }

    @Test("mono small buffer")
    func monoSmallBuffer() {
        // 1 frame * 1 ch * 4 = 4 bytes
        #expect(audioFrameCount(byteSize: 4, channelCount: 1) == 1)
    }

    // MARK: - Stereo (2 channels)

    @Test("stereo standard buffer")
    func stereoStandardBuffer() {
        // 512 frames * 2 channels * 4 bytes = 4096 bytes
        #expect(audioFrameCount(byteSize: 4096, channelCount: 2) == 512)
    }

    @Test("stereo odd byte size")
    func stereoOddByteSize() {
        // 10 frames * 2 channels * 4 bytes = 80 bytes
        #expect(audioFrameCount(byteSize: 80, channelCount: 2) == 10)
    }

    @Test("stereo frame count is half of naive sample count")
    func stereoFrameCountIsHalfOfNaive() {
        let byteSize: UInt32 = 4096
        let naiveSampleCount = byteSize / UInt32(MemoryLayout<Float>.size)
        let correctFrameCount = audioFrameCount(byteSize: byteSize, channelCount: 2)
        #expect(correctFrameCount == naiveSampleCount / 2)
    }

    // MARK: - Edge cases

    @Test("zero byte size returns zero")
    func zeroByteSizeReturnsZero() {
        #expect(audioFrameCount(byteSize: 0, channelCount: 1) == 0)
        #expect(audioFrameCount(byteSize: 0, channelCount: 2) == 0)
    }

    @Test("zero channel count treated as mono")
    func zeroChannelCountTreatedAsMono() {
        #expect(audioFrameCount(byteSize: 4096, channelCount: 0) == 1024)
    }

    @Test("high channel count")
    func highChannelCount() {
        // 8-channel surround: 128 frames * 8 ch * 4 = 4096 bytes
        #expect(audioFrameCount(byteSize: 4096, channelCount: 8) == 128)
    }

    @Test("non-aligned byte size truncates")
    func nonAlignedByteSizeTruncates() {
        // 5 bytes with 1 channel: 5 / 4 = 1 frame (integer division)
        #expect(audioFrameCount(byteSize: 5, channelCount: 1) == 1)
    }
}
