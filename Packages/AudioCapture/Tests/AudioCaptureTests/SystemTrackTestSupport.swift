import AudioToolbox
import AVFoundation
import Foundation
@testable import AudioCapture

/// A temporary ADTS AAC file set up as `LiveSystemCaptureEngine` sets up
/// its file: 24 kHz output, interleaved Float32 client format at the tap's
/// rate and channel count.
final class SystemTestFile {
    let url: URL
    let file: ExtAudioFileRef
    private var disposed = false

    /// - Parameter setsClientFormat: False leaves the client format compressed,
    ///   so every PCM write fails.
    init(clientRate: Double, channelCount: UInt32 = 1, setsClientFormat: Bool = true) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("system-track-\(UUID()).aac")
        let encoder = EncoderSettings.voice
        var outputASBD = encoder.outputASBD()
        var fileRef: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(
            url as CFURL, encoder.fileType, &outputASBD, nil,
            AudioFileFlags.eraseFile.rawValue, &fileRef
        )
        guard createStatus == noErr, let ref = fileRef else {
            throw SystemTestFileError("ExtAudioFileCreateWithURL failed: \(createStatus)")
        }
        file = ref
        guard setsClientFormat else { return }
        do {
            try setClientFormat(rate: clientRate, channelCount: channelCount)
        } catch {
            ExtAudioFileDispose(file)
            throw error
        }
    }

    /// Sets the interleaved Float32 client format. ExtAudioFile refuses
    /// any change after the first write (-66565).
    private func setClientFormat(rate: Double, channelCount: UInt32) throws {
        let bytesPerFrame = UInt32(MemoryLayout<Float>.size) * channelCount
        var clientASBD = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let status = ExtAudioFileSetProperty(
            file, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientASBD
        )
        guard status == noErr else {
            throw SystemTestFileError("Client format set failed: \(status)")
        }
    }

    /// Writes a non-zero tone buffer in the current client format.
    func writeToneBuffer(frameCount: UInt32, channelCount: UInt32) {
        let sampleCount = Int(frameCount * channelCount)
        var samples = [Float](repeating: 0, count: sampleCount)
        for idx in 0 ..< sampleCount {
            samples[idx] = 0.2 * sin(Float(idx) * 0.1)
        }
        samples.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            let buffer = AudioBuffer(
                mNumberChannels: channelCount,
                mDataByteSize: UInt32(sampleCount * MemoryLayout<Float>.size),
                mData: base
            )
            var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
            let status = ExtAudioFileWrite(file, frameCount, &bufferList)
            precondition(status == noErr, "Test tone write failed: \(status)")
        }
    }

    /// Closes the file and reads back the decoded duration in seconds.
    func fileDuration() throws -> Double {
        close()
        let audio = try AVAudioFile(forReading: url)
        return Double(audio.length) / audio.processingFormat.sampleRate
    }

    /// Closes the file and decodes it to mono samples at 24 kHz.
    func decodedSamples() throws -> [Float] {
        close()
        return try MicCaptureTestHelpers.decodedSamples(url)
    }

    func dispose() {
        close()
        try? FileManager.default.removeItem(at: url)
    }

    private func close() {
        if !disposed {
            ExtAudioFileDispose(file)
            disposed = true
        }
    }

    deinit {
        dispose()
    }
}

struct SystemTestFileError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) {
        description = message
    }
}

/// Hands a `SystemWriteStep` interleaved tone buffers with contiguous host
/// times, as the IOProc ring delivers them.
struct SystemToneFeed {
    let sampleRate: Double
    let channelCount: Int
    let bufferFrames: Int

    /// Every interleaved sample handed to the step, in order.
    private(set) var played: [Float] = []

    private var frameIndex = 0
    private var hostNanos: UInt64

    init(sampleRate: Double, channelCount: Int = 1, bufferFrames: Int = 512, startSeconds: Double = 1) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bufferFrames = bufferFrames
        hostNanos = UInt64((startSeconds * 1_000_000_000).rounded())
    }

    mutating func play(seconds: Double, into step: SystemWriteStep, file: ExtAudioFileRef) {
        var remaining = Int((seconds * sampleRate).rounded())
        while remaining > 0 {
            let count = min(bufferFrames, remaining)
            var samples = [Float](repeating: 0, count: count * channelCount)
            for frame in 0 ..< count {
                let time = Double(frameIndex + frame) / sampleRate
                for channel in 0 ..< channelCount {
                    // Each channel its own tone, so interleaving is visible.
                    let hertz = 300.0 + 200 * Double(channel)
                    samples[frame * channelCount + channel] = Float(0.3 * sin(2 * Double.pi * hertz * time))
                }
            }
            played.append(contentsOf: samples)
            let hostTime = AudioConvertNanosToHostTime(hostNanos)
            let channels = channelCount
            samples.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                let entry = AudioRingBuffer.Entry(
                    data: base,
                    dataByteSize: UInt32(raw.count),
                    frameCount: UInt32(count),
                    channelCount: UInt32(channels),
                    hostTime: hostTime
                )
                step.write(entry, sampleRate: sampleRate, to: file)
            }
            frameIndex += count
            hostNanos += UInt64((Double(count) / sampleRate * 1_000_000_000).rounded())
            remaining -= count
        }
    }

    /// Lets host time pass with no buffers, as during a reconnect.
    mutating func pause(seconds: Double) {
        hostNanos += UInt64((seconds * 1_000_000_000).rounded())
    }
}
