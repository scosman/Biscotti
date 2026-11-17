import AVFoundation
import Foundation

/// WAV file read/write utilities for the experiment.
public enum WAVFile {
    /// Write Float32 mono samples at 16 kHz to a WAV file using AVAudioFile.
    public static func writeFloat32Mono16k(samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw WAVFileError.formatCreationFailed
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw WAVFileError.bufferCreationFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channelData = buffer.floatChannelData else {
            throw WAVFileError.channelDataUnavailable
        }
        samples.withUnsafeBufferPointer { src in
            channelData[0].update(from: src.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    /// Read a WAV file and return Float32 mono samples and the sample rate.
    public static func readFloat32Mono(url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: file.fileFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw WAVFileError.formatCreationFailed
        }
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw WAVFileError.bufferCreationFailed
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else {
            throw WAVFileError.channelDataUnavailable
        }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        return (samples, file.fileFormat.sampleRate)
    }

    /// Build an in-memory 16-bit PCM WAV (44-byte RIFF header + samples) for upload.
    /// Samples are clamped to [-1, 1] and rounded to Int16.
    public static func int16WAVData(samples: [Float], range: Range<Int>? = nil) -> Data {
        let slice = range.map { samples[$0] } ?? ArraySlice(samples)
        let sampleCount = slice.count
        let dataChunkSize = sampleCount * 2
        let fileSize = 36 + dataChunkSize

        var data = Data(capacity: 44 + dataChunkSize)

        // RIFF header
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        data.appendLittleEndian(UInt32(fileSize))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // fmt chunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        data.appendLittleEndian(UInt32(16))                 // chunk size
        data.appendLittleEndian(UInt16(1))                  // PCM format
        data.appendLittleEndian(UInt16(1))                  // 1 channel
        data.appendLittleEndian(UInt32(16000))              // sample rate
        data.appendLittleEndian(UInt32(32000))              // byte rate (16000 * 1 * 2)
        data.appendLittleEndian(UInt16(2))                  // block align (1 * 2)
        data.appendLittleEndian(UInt16(16))                 // bits per sample

        // data chunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        data.appendLittleEndian(UInt32(dataChunkSize))

        for sample in slice {
            let clamped = max(Float(-1.0), min(Float(1.0), sample))
            let scaled = clamped * 32768.0
            let rounded = scaled.rounded(.toNearestOrAwayFromZero)
            let value = Int16(clamping: Int(rounded))
            data.appendLittleEndian(value)
        }

        return data
    }
}

public enum WAVFileError: Error {
    case formatCreationFailed
    case bufferCreationFailed
    case channelDataUnavailable
}

// MARK: - Data helpers

extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        var v = value.littleEndian
        withUnsafePointer(to: &v) { ptr in
            append(UnsafeBufferPointer(start: ptr, count: 1))
        }
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        var v = value.littleEndian
        withUnsafePointer(to: &v) { ptr in
            append(UnsafeBufferPointer(start: ptr, count: 1))
        }
    }

    mutating func appendLittleEndian(_ value: Int16) {
        var v = value.littleEndian
        withUnsafePointer(to: &v) { ptr in
            append(UnsafeBufferPointer(start: ptr, count: 1))
        }
    }
}
