import AudioToolbox
import AVFoundation
import Testing
@testable import AudioCapture

@Suite("VPIOBufferHelper")
struct VPIOBufferHelperTests {
    // MARK: - extractChannel0

    @Test("extractChannel0 copies channel 0 from a multichannel buffer")
    func extractChannel0Multichannel() throws {
        let channels: AVAudioChannelCount = 4
        let frames: AVAudioFrameCount = 128
        let sampleRate = 48000.0

        let format = try #require(discreteFormat(
            sampleRate: sampleRate, channels: channels
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames

        let data = try #require(buffer.floatChannelData)
        for channel in 0 ..< Int(channels) {
            let value = Float(channel + 1) * 0.1
            for frame in 0 ..< Int(frames) {
                data[channel][frame] = value
            }
        }

        let mono = try #require(VPIOBufferHelper.extractChannel0(buffer))

        #expect(mono.format.channelCount == 1)
        #expect(mono.format.sampleRate == sampleRate)
        #expect(mono.frameLength == frames)

        let monoData = try #require(mono.floatChannelData)
        for frame in 0 ..< Int(frames) {
            #expect(monoData[0][frame] == 0.1)
        }
    }

    @Test("extractChannel0 passes through a mono buffer unchanged")
    func extractChannel0Mono() throws {
        let frames: AVAudioFrameCount = 64
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames

        let data = try #require(buffer.floatChannelData)
        for frame in 0 ..< Int(frames) {
            data[0][frame] = 0.42
        }

        let result = try #require(VPIOBufferHelper.extractChannel0(buffer))

        #expect(result.format.channelCount == 1)
        #expect(result.frameLength == frames)
        let outData = try #require(result.floatChannelData)
        #expect(outData[0][0] == 0.42)
    }

    @Test("extractChannel0 returns nil for empty buffer")
    func extractChannel0EmptyBuffer() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        #expect(VPIOBufferHelper.extractChannel0(buffer) == nil)
    }

    @Test("extractChannel0 preserves sample rate from source")
    func extractChannel0PreservesSampleRate() throws {
        let sampleRate = 96000.0
        let frames: AVAudioFrameCount = 32
        let format = try #require(discreteFormat(
            sampleRate: sampleRate, channels: 9
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        buffer.floatChannelData?[0].update(repeating: 0.77, count: Int(frames))

        let result = try #require(VPIOBufferHelper.extractChannel0(buffer))
        #expect(result.format.sampleRate == sampleRate)
    }

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
            VPIOBufferHelper.convert(source, to: targetFormat, using: converter)
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
        let result = VPIOBufferHelper.convert(source, to: targetFormat, using: converter)
        #expect(result == nil)
    }

    // MARK: - Test helpers

    /// Builds a non-interleaved float32 format with a discrete channel layout.
    /// `AVAudioFormat(commonFormat:channels:interleaved:)` returns nil for >2
    /// channels without a layout -- the same trap VPIO's ~9-channel surprise
    /// triggers at runtime (where the real buffers already carry a layout).
    private func discreteFormat(
        sampleRate: Double,
        channels: AVAudioChannelCount
    ) -> AVAudioFormat? {
        let layoutTag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        guard let layout = AVAudioChannelLayout(layoutTag: layoutTag) else {
            return nil
        }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            interleaved: false,
            channelLayout: layout
        )
    }
}
