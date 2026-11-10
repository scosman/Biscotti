import AudioToolbox
import AVFoundation
import Testing
@testable import AudioCapture

@Suite("MicBufferHelper")
struct MicBufferHelperTests {
    // MARK: - convert

    @Test("convert resamples mono buffer to target format")
    func convertResamplesMono() throws {
        let sourceRate = 48000.0
        let targetRate = 24000.0
        let frames: AVAudioFrameCount = 480

        let sourceFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceRate,
            channels: 1,
            interleaved: false
        ))
        let targetFormat = try #require(AVAudioFormat(
            standardFormatWithSampleRate: targetRate, channels: 1
        ))
        let converter = try #require(AVAudioConverter(from: sourceFormat, to: targetFormat))

        let source = try #require(AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames))
        source.frameLength = frames
        source.floatChannelData?[0].update(repeating: 0.5, count: Int(frames))

        let result = try #require(
            MicBufferHelper.convert(source, to: targetFormat, using: converter)
        )

        #expect(result.format.sampleRate == targetRate)
        #expect(result.format.channelCount == 1)
        #expect(result.frameLength > 0)
        #expect(result.frameLength <= frames)
    }

    @Test("convert returns nil for zero-frame source")
    func convertZeroFrames() throws {
        let sourceFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        ))
        let targetFormat = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 24000, channels: 1
        ))
        let converter = try #require(AVAudioConverter(from: sourceFormat, to: targetFormat))

        let source = try #require(AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 480))
        let result = MicBufferHelper.convert(source, to: targetFormat, using: converter)
        #expect(result == nil)
    }
}
