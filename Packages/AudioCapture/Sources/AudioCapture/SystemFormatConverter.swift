import AudioToolbox
@preconcurrency import AVFoundation
import os

private let logger = Logger(subsystem: "net.scosman.biscotti.audiocapture", category: "LiveSystemCapture")

/// Converts system-tap buffers to the system track's fixed client format.
///
/// The tap delivers audio in the output device's format, which can change
/// at any reconnect: AirPods drop from 48 kHz to 24 kHz in a call, some USB
/// devices run at 44.1 kHz, and the mic engine can change the output rate
/// to match its input. `ExtAudioFile` takes a client format only before
/// the first write; a later change fails with `-66565`
/// (`kExtAudioFileError_InvalidOperationOrder`). So the system file keeps
/// one client format for the whole recording, `clientFormat`, and every tap
/// buffer is converted to it here. A new tap format only rebuilds the
/// converter.
///
/// **Thread-safety:** not thread-safe. Used only by the system writer thread
/// (and by `LiveSystemCaptureEngine.openAudioFile` before that thread starts).
final class SystemFormatConverter {
    /// 48 kHz mono interleaved Float32: what the mono mixdown tap delivers
    /// on a 48 kHz output device (built-in speakers, AirPods outside a call).
    /// On that common path, buffers reach the encoder unchanged, with the
    /// same client format as before the format was fixed. The encoder then
    /// resamples to the file's 24 kHz.
    static let clientFormat: AVAudioFormat = {
        guard let format = interleavedFloatFormat(sampleRate: 48000, channelCount: 1) else {
            preconditionFailure("AVAudioFormat refused 48 kHz mono Float32")
        }
        return format
    }()

    /// Output room beyond a buffer's own converted length, for frames the
    /// converter held back on earlier calls. Without it, the held-back
    /// frames build up until the converter skips a whole input buffer.
    private static let outputSlackFrames: AVAudioFrameCount = 1024

    /// Tap format of the last buffer; nil before the first one.
    private var sourceFormat: AVAudioFormat?

    /// Nil when `sourceFormat` is already the client format, or when no
    /// converter could be built for it.
    private var converter: AVAudioConverter?

    /// Returns `entry` in `clientFormat`, or nil if nothing can be written
    /// yet (the converter is holding the frames) or the conversion failed.
    ///
    /// - Parameters:
    ///   - entry: an interleaved Float32 tap buffer.
    ///   - sampleRate: the tap's sample rate for this buffer (Hz).
    func convert(_ entry: AudioRingBuffer.Entry, sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let format = Self.interleavedFloatFormat(sampleRate: sampleRate, channelCount: max(entry.channelCount, 1)),
              let input = Self.copy(entry, format: format)
        else { return nil }

        if format != sourceFormat {
            prepare(for: format)
        }
        if format == Self.clientFormat {
            return input
        }
        guard let converter else { return nil }
        return Self.convert(input, using: converter)
    }

    /// The tap's sample layout: packed, interleaved Float32.
    static func interleavedFloatFormat(sampleRate: Double, channelCount: UInt32) -> AVAudioFormat? {
        let bytesPerFrame = UInt32(MemoryLayout<Float>.size) * channelCount
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        // AVAudioFormat needs a channel layout for more than two channels.
        let layout = channelCount > 2
            ? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channelCount)
            : nil
        return AVAudioFormat(streamDescription: &description, channelLayout: layout)
    }

    /// Makes `format` the current tap format and builds its converter, or
    /// none when `format` is already the client format. Logs once per
    /// format change.
    private func prepare(for format: AVAudioFormat) {
        sourceFormat = format
        converter = nil
        let rate = format.sampleRate
        let channels = format.channelCount
        if format == Self.clientFormat {
            logger.notice("System tap format \(rate, privacy: .public) Hz \(channels, privacy: .public) ch is the client format; writing it unconverted")
            return
        }
        guard let converter = AVAudioConverter(from: format, to: Self.clientFormat) else {
            logger.error("No converter from system tap format \(rate, privacy: .public) Hz \(channels, privacy: .public) ch; dropping its buffers")
            return
        }
        // Keep channel 0. ExtAudioFile did the same when the client format
        // had the tap's channel count; without a map, a discrete
        // multichannel source converts to silence.
        if channels > 1 {
            converter.channelMap = [0]
        }
        self.converter = converter
        let clientRate = Self.clientFormat.sampleRate
        let clientChannels = Self.clientFormat.channelCount
        logger.notice(
            "System tap format \(rate, privacy: .public) Hz \(channels, privacy: .public) ch; converting to the \(clientRate, privacy: .public) Hz \(clientChannels, privacy: .public) ch client format"
        )
    }

    /// Copies the ring slot into a new buffer. The converter can keep a
    /// partly used input buffer for its next call, and the ring may reuse
    /// the slot by then.
    private static func copy(_ entry: AudioRingBuffer.Entry, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let byteCount = Int(entry.frameCount) * Int(format.streamDescription.pointee.mBytesPerFrame)
        guard byteCount > 0, byteCount <= Int(entry.dataByteSize),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: entry.frameCount),
              let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData
        else { return nil }
        destination.copyMemory(from: entry.data, byteCount: byteCount)
        buffer.frameLength = entry.frameCount
        return buffer
    }

    /// Hands `input` to the converter once and returns what it produced:
    /// nil when it produced nothing yet or the conversion failed.
    private static func convert(_ input: AVAudioPCMBuffer, using converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let converted = Double(input.frameLength) * clientFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(converted.rounded(.up)) + outputSlackFrames
        guard let output = AVAudioPCMBuffer(pcmFormat: clientFormat, frameCapacity: capacity) else { return nil }

        var error: NSError?
        nonisolated(unsafe) var didProvideInput = false
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if didProvideInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            logger.error("System tap conversion failed: \(error?.localizedDescription ?? "unknown error", privacy: .public)")
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }
}
