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

// MARK: - leadingSilenceFrameCount

@Suite("leadingSilenceFrameCount")
struct LeadingSilenceFrameCountTests {
    // Convenience: 1 second at 24 kHz = 12000 frames
    private let rate = 24000.0

    @Test("positive gap computes correct frame count")
    func positiveGap() {
        // System starts 0.5 s after mic at 24 kHz => 12_000 frames
        let frames = leadingSilenceFrameCount(
            systemHostTimeNanos: 1_500_000_000, // 1.5 s
            micAnchorSeconds: 1.0,
            systemStartWall: 0.5,
            currentWall: 1.5,
            sampleRate: rate
        )
        #expect(frames == 12000)
    }

    @Test("zero mic anchor returns 0")
    func zeroMicAnchor() {
        let frames = leadingSilenceFrameCount(
            systemHostTimeNanos: 1_000_000_000,
            micAnchorSeconds: 0,
            systemStartWall: 0,
            currentWall: 1.0,
            sampleRate: rate
        )
        #expect(frames == 0)
    }

    @Test("negative mic anchor returns 0")
    func negativeMicAnchor() {
        let frames = leadingSilenceFrameCount(
            systemHostTimeNanos: 1_000_000_000,
            micAnchorSeconds: -1.0,
            systemStartWall: 0,
            currentWall: 1.0,
            sampleRate: rate
        )
        #expect(frames == 0)
    }

    @Test("zero system host time returns 0")
    func zeroSystemHostTime() {
        let frames = leadingSilenceFrameCount(
            systemHostTimeNanos: 0,
            micAnchorSeconds: 1.0,
            systemStartWall: 0,
            currentWall: 1.0,
            sampleRate: rate
        )
        #expect(frames == 0)
    }

    @Test("non-positive gap returns 0")
    func nonPositiveGap() {
        // System starts BEFORE mic => gap is negative => 0 frames
        let frames = leadingSilenceFrameCount(
            systemHostTimeNanos: 500_000_000, // 0.5 s
            micAnchorSeconds: 1.0,
            systemStartWall: 0,
            currentWall: 1.0,
            sampleRate: rate
        )
        #expect(frames == 0)
    }

    @Test("gap exactly zero returns 0")
    func gapExactlyZero() {
        let frames = leadingSilenceFrameCount(
            systemHostTimeNanos: 1_000_000_000,
            micAnchorSeconds: 1.0,
            systemStartWall: 0,
            currentWall: 1.0,
            sampleRate: rate
        )
        #expect(frames == 0)
    }

    @Test("wall-time bound clamps excessive gap")
    func wallTimeBoundClampsGap() {
        // Raw gap = 10 s, but capture only running for 2 s => bound = 3 s
        let frames = leadingSilenceFrameCount(
            systemHostTimeNanos: 11_000_000_000,
            micAnchorSeconds: 1.0,
            systemStartWall: 8.0,
            currentWall: 10.0,
            sampleRate: rate
        )
        // wallBound = (10 - 8) + 1 = 3 s => 72_000 frames
        #expect(frames == 72000)
    }

    @Test("absolute max clamps very large gap")
    func absoluteMaxClamps() {
        let frames = leadingSilenceFrameCount(
            systemHostTimeNanos: 10_000_000_000_000,
            micAnchorSeconds: 1.0,
            systemStartWall: 0,
            currentWall: 10000,
            sampleRate: rate,
            maxLeadingSilenceSeconds: 5.0
        )
        // maxLeading = 5 s => 120_000 frames
        #expect(frames == 120_000)
    }

    @Test("zero sample rate returns 0")
    func zeroSampleRate() {
        let frames = leadingSilenceFrameCount(
            systemHostTimeNanos: 2_000_000_000,
            micAnchorSeconds: 1.0,
            systemStartWall: 0,
            currentWall: 2.0,
            sampleRate: 0
        )
        #expect(frames == 0)
    }
}
