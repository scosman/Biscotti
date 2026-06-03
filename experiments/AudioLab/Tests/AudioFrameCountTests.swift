import XCTest

@testable import AudioLab

final class AudioFrameCountTests: XCTestCase {

    // MARK: - Mono (1 channel)

    func testMonoStandardBuffer() {
        // 1024 frames * 1 channel * 4 bytes = 4096 bytes
        let result = audioFrameCount(byteSize: 4096, channelCount: 1)
        XCTAssertEqual(result, 1024)
    }

    func testMonoSmallBuffer() {
        // 1 frame * 1 ch * 4 = 4 bytes
        let result = audioFrameCount(byteSize: 4, channelCount: 1)
        XCTAssertEqual(result, 1)
    }

    // MARK: - Stereo (2 channels)

    func testStereoStandardBuffer() {
        // 512 frames * 2 channels * 4 bytes = 4096 bytes
        let result = audioFrameCount(byteSize: 4096, channelCount: 2)
        XCTAssertEqual(result, 512)
    }

    func testStereoOddByteSize() {
        // 10 frames * 2 channels * 4 bytes = 80 bytes
        let result = audioFrameCount(byteSize: 80, channelCount: 2)
        XCTAssertEqual(result, 10)
    }

    /// Verifies the bug that was fixed: previously the code computed
    /// byteSize / sizeof(Float) which ignored channelCount, producing
    /// a frame count that was N-times too large for N-channel buffers.
    func testStereoFrameCountIsHalfOfNaiveSampleCount() {
        let byteSize: UInt32 = 4096
        let naiveSampleCount = byteSize / UInt32(MemoryLayout<Float>.size) // 1024 -- the old bug
        let correctFrameCount = audioFrameCount(byteSize: byteSize, channelCount: 2) // 512
        XCTAssertEqual(correctFrameCount, naiveSampleCount / 2,
                       "Stereo frame count must be half the naive sample count")
    }

    // MARK: - Edge cases

    func testZeroByteSizeReturnsZero() {
        XCTAssertEqual(audioFrameCount(byteSize: 0, channelCount: 1), 0)
        XCTAssertEqual(audioFrameCount(byteSize: 0, channelCount: 2), 0)
    }

    func testZeroChannelCountTreatedAsMono() {
        // channelCount == 0 should be treated as 1 (defensive)
        let result = audioFrameCount(byteSize: 4096, channelCount: 0)
        XCTAssertEqual(result, 1024)
    }

    func testHighChannelCount() {
        // 8-channel surround: 128 frames * 8 ch * 4 = 4096 bytes
        let result = audioFrameCount(byteSize: 4096, channelCount: 8)
        XCTAssertEqual(result, 128)
    }

    func testNonAlignedByteSizeTruncates() {
        // 5 bytes with 1 channel: 5 / 4 = 1 frame (integer division truncates)
        let result = audioFrameCount(byteSize: 5, channelCount: 1)
        XCTAssertEqual(result, 1)
    }
}
