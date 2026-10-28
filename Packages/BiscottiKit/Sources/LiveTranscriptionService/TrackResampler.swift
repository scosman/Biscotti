import AudioCapture
import AVFoundation
import LiveTranscriptModel

/// Where the pump drains one track's blocks. `LiveAudioQueue` is the real one.
public protocol LiveBlockSource: AnyObject, Sendable {
    /// Hands every block published since the last call to `body`, in order.
    /// One consumer at a time.
    func drain(_ body: (LiveAudioBlock) -> Void)
}

/// One recording's two tracks.
public protocol LiveAudioSource: Sendable {
    var micBlocks: any LiveBlockSource { get }
    var systemBlocks: any LiveBlockSource { get }
}

extension LiveAudioQueue: LiveBlockSource {}

extension LiveAudioTap: LiveAudioSource {
    public var micBlocks: any LiveBlockSource {
        mic
    }

    public var systemBlocks: any LiveBlockSource {
        system
    }
}

/// Turns one track's interleaved blocks at one format into 16 kHz mono
/// samples: channels are averaged, then one persistent `AVAudioConverter`
/// resamples, so its filter keeps its state from block to block.
final class TrackResampler {
    let sampleRate: Double
    let channelCount: Int
    private let monoFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    /// Nil when the source is already 16 kHz.
    private let converter: AVAudioConverter?

    init?(sampleRate: Double, channelCount: Int) {
        guard sampleRate > 0, channelCount > 0,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: LiveAudioChunk.sampleRate, channels: 1, interleaved: false)
        else { return nil }
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.monoFormat = monoFormat
        self.outputFormat = outputFormat
        if sampleRate == LiveAudioChunk.sampleRate {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: monoFormat, to: outputFormat) else { return nil }
            self.converter = converter
        }
    }

    func matches(sampleRate: Double, channelCount: Int) -> Bool {
        self.sampleRate == sampleRate && self.channelCount == channelCount
    }

    /// The 16 kHz samples this block completes. The resampler may keep a few
    /// until the next block or `flush()`.
    func convert(_ interleaved: UnsafeBufferPointer<Float>) -> [Float] {
        let frames = interleaved.count / channelCount
        guard frames > 0 else { return [] }
        guard let converter else { return downmix(interleaved, frames: frames) }
        // A fresh input buffer for every call: the converter may keep reading
        // a buffer it did not use up on the next call.
        guard let input = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)),
              let channel = input.floatChannelData?[0]
        else { return [] }
        input.frameLength = AVAudioFrameCount(frames)
        downmix(interleaved, frames: frames, into: channel)
        let source = OneShotInput(input)
        return run(converter, capacity: frames) { _, status in source.next(status) }
    }

    /// Releases the samples the resampler still holds and resets it, at the
    /// end of a run.
    func flush() -> [Float] {
        guard let converter else { return [] }
        let samples = run(converter, capacity: 1024) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        converter.reset()
        return samples
    }

    private func run(_ converter: AVAudioConverter, capacity frames: Int, input: @escaping AVAudioConverterInputBlock) -> [Float] {
        let ratio = LiveAudioChunk.sampleRate / sampleRate
        // A resampler may release a few more frames than this call alone makes.
        let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var error: NSError?
        let status = converter.convert(to: output, error: &error, withInputFrom: input)
        guard status != .error, let samples = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
    }

    private func downmix(_ interleaved: UnsafeBufferPointer<Float>, frames: Int) -> [Float] {
        [Float](unsafeUninitializedCapacity: frames) { buffer, count in
            if let base = buffer.baseAddress {
                downmix(interleaved, frames: frames, into: base)
            }
            count = frames
        }
    }

    private func downmix(_ interleaved: UnsafeBufferPointer<Float>, frames: Int, into mono: UnsafeMutablePointer<Float>) {
        guard channelCount > 1 else {
            if let base = interleaved.baseAddress { mono.update(from: base, count: frames) }
            return
        }
        let scale = 1 / Float(channelCount)
        for frame in 0 ..< frames {
            var sum: Float = 0
            for channel in 0 ..< channelCount {
                sum += interleaved[frame * channelCount + channel]
            }
            mono[frame] = sum * scale
        }
    }
}

/// Gives the converter one buffer, then reports that no more input is ready
/// yet, so a resampler keeps its remainder for the next block instead of
/// flushing it.
///
/// `@unchecked`: the converter calls its input block synchronously, inside
/// `convert`, on the calling thread; nothing else touches the buffer.
private final class OneShotInput: @unchecked Sendable {
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
