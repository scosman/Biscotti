import AVFoundation
import Foundation
import Testing
@testable import LiveTranscription

@Suite("LiveSampleConverter")
struct LiveSampleConverterTests {
    @Test("at the same rate, Float32 becomes Int16 sample for sample")
    func convertsFloatToInt16() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false))
        let converter = try #require(LiveSampleConverter(outputFormat: format))

        let output = try #require(converter.convert([0, 0.5, -0.5, 1]))

        #expect(output.frameLength == 4)
        let samples = try Array(UnsafeBufferPointer(start: #require(output.int16ChannelData?[0]), count: 4))
        #expect(samples == [0, 16384, -16384, 32767])
    }

    @Test("resampling keeps its state across chunks")
    func resamplesAcrossChunks() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false))
        let converter = try #require(LiveSampleConverter(outputFormat: format))
        let tone = (0 ..< 40000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16000)) * 0.5 }

        let frames = try stride(from: 0, to: tone.count, by: 4000).reduce(0) { total, start in
            try total + Int(#require(converter.convert(Array(tone[start ..< start + 4000]))).frameLength)
        }

        #expect(abs(frames - 120_000) < 200, "three output frames per input frame, less the resampler's delay")
    }
}
