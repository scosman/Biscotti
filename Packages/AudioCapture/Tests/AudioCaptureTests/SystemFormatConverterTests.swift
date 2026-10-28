import AudioToolbox
import AVFoundation
import Foundation
import Testing
@testable import AudioCapture

@Suite("System format converter")
struct SystemFormatConverterTests {
    /// The client format must be the one the system file used before it was
    /// fixed, for the usual 48 kHz mono tap, so that common path is unchanged.
    @Test("Client format is the previous client format of a 48 kHz mono tap")
    func clientFormatMatchesPreviousCommonPath() {
        let client = SystemFormatConverter.clientFormat.streamDescription.pointee
        #expect(client.mSampleRate == 48000)
        #expect(client.mFormatID == kAudioFormatLinearPCM)
        #expect(client.mFormatFlags == kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)
        #expect(client.mBytesPerPacket == 4)
        #expect(client.mFramesPerPacket == 1)
        #expect(client.mBytesPerFrame == 4)
        #expect(client.mChannelsPerFrame == 1)
        #expect(client.mBitsPerChannel == 32)
    }

    /// On the common path the converter must not touch the audio: a 48 kHz
    /// mono buffer comes back sample for sample.
    @Test("A 48 kHz mono tap buffer passes through unchanged")
    func clientFormatPassesThrough() throws {
        let converter = SystemFormatConverter()
        var samples = (0 ..< 441).map { Float(sin(Double($0) * 0.05)) }
        let output = try #require(convert(&samples, frames: 441, channels: 1, rate: 48000, with: converter))
        let data = try #require(output.floatChannelData?[0])
        #expect(output.frameLength == 441)
        #expect(Array(UnsafeBufferPointer(start: data, count: 441)) == samples)
    }

    /// AVAudioConverter turns a discrete multichannel source into silence
    /// unless it is told which channel to keep.
    @Test("A multichannel tap keeps channel 0", arguments: [2, 3])
    func multichannelKeepsChannelZero(channels: Int) throws {
        let converter = SystemFormatConverter()
        let frames = 4800
        var samples = [Float](repeating: 0.1, count: frames * channels)
        for frame in 0 ..< frames {
            samples[frame * channels] = 0.5
        }
        let output = try #require(convert(&samples, frames: frames, channels: UInt32(channels), rate: 48000, with: converter))
        let data = try #require(output.floatChannelData?[0])
        #expect(abs(data[Int(output.frameLength) / 2] - 0.5) < 0.001)
    }

    /// A converted length that is not a whole number of frames used to make
    /// the converter fall behind until it skipped a whole input buffer.
    @Test("Resampling many odd buffers loses only the converter's latency")
    func resamplingKeepsEveryBuffer() {
        let converter = SystemFormatConverter()
        let frames = 512 // 557.3 frames at 48 kHz
        let calls = 5000
        var samples = [Float](repeating: 0.1, count: frames)
        var total = 0
        for _ in 0 ..< calls {
            if let output = convert(&samples, frames: frames, channels: 1, rate: 44100, with: converter) {
                total += Int(output.frameLength)
            }
        }
        let expected = Double(frames * calls) * 48000 / 44100
        #expect(expected - Double(total) < 100, "Converted \(total) frames of \(expected): buffers were dropped")
    }

    /// Wraps `samples` in a ring-buffer entry, as the IOProc enqueues them,
    /// and converts it.
    private func convert(
        _ samples: inout [Float],
        frames: Int,
        channels: UInt32,
        rate: Double,
        with converter: SystemFormatConverter
    ) -> AVAudioPCMBuffer? {
        samples.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            let entry = AudioRingBuffer.Entry(
                data: base,
                dataByteSize: UInt32(raw.count),
                frameCount: UInt32(frames),
                channelCount: channels,
                hostTime: 0
            )
            return converter.convert(entry, sampleRate: rate)
        }
    }
}
