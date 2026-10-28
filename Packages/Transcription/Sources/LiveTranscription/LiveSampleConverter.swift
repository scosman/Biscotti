import AVFoundation
import LiveTranscriptModel

/// Converts 16 kHz mono Float32 chunks to an analyzer's audio format with one
/// persistent `AVAudioConverter`, so a resampler keeps its state between
/// chunks. The session sends missing audio as silence, so the input stays continuous.
struct LiveSampleConverter {
    /// The live chunks' format. The initializer is failable, though a standard
    /// format like this one does not fail.
    static let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: LiveAudioChunk.sampleRate, channels: 1, interleaved: false)

    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(outputFormat: AVAudioFormat) {
        guard let inputFormat = Self.inputFormat, let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    /// - Returns: The converted audio, or nil when the converter fails.
    func convert(_ samples: [Float]) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        // A resampler may release a few more frames than this chunk alone makes.
        let capacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 64
        guard let input = buffer(holding: samples),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        else { return nil }

        if outputFormat.sampleRate == inputFormat.sampleRate {
            // The plain conversion does no sample rate conversion, and needs none here.
            do {
                try converter.convert(to: output, from: input)
            } catch {
                return nil
            }
            return output
        }
        let source = SingleInput(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in source.next(inputStatus) }
        return status == .error ? nil : output
    }

    private func buffer(holding samples: [Float]) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: source.count)
            }
        }
        return buffer
    }
}

/// Gives the converter one chunk, then reports that no more input is ready
/// yet, so a resampler keeps its remainder for the next chunk instead of
/// flushing it.
///
/// `@unchecked`: the converter calls its input block synchronously, inside
/// `convert`, on the calling thread; nothing else touches the buffer.
private final class SingleInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}
