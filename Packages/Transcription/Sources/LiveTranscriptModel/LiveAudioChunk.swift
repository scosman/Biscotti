import Foundation

/// A short run of one track's audio, resampled for the live engine.
public struct LiveAudioChunk: Sendable, Equatable {
    /// The sample rate of `samples`.
    public static let sampleRate: Double = 16000

    public var track: LiveTrack
    /// Seconds on the recording timeline.
    public var startTime: TimeInterval
    /// 16 kHz mono Float32.
    public var samples: [Float]
    /// True for the first chunk after a gap.
    public var isDiscontinuity: Bool
    /// True for audio handed to the engine well behind the newest captured
    /// audio: kept while no engine ran, or while it fell behind. The engine
    /// catches up on it in long windows before it streams again.
    public var isBackfill: Bool

    public init(track: LiveTrack, startTime: TimeInterval, samples: [Float], isDiscontinuity: Bool = false, isBackfill: Bool = false) {
        self.track = track
        self.startTime = startTime
        self.samples = samples
        self.isDiscontinuity = isDiscontinuity
        self.isBackfill = isBackfill
    }

    public var duration: TimeInterval {
        Double(samples.count) / Self.sampleRate
    }

    public var endTime: TimeInterval {
        startTime + duration
    }
}

/// Why `LiveAudioChunk(xpcData:)` rejected its input.
public enum LiveAudioChunkCodingError: Error, Equatable {
    /// Shorter than the length prefix, or than the header it announces.
    case truncatedHeader
    case malformedHeader
    case sampleCountMismatch(expected: Int, actual: Int)
}

// MARK: - XPC codec

/// Chunks cross XPC about four times a second per track, so samples travel as
/// raw bytes instead of JSON numbers. Layout: an 8-byte little-endian header
/// length, a JSON `Header`, then little-endian Float32 samples.
extension LiveAudioChunk {
    private struct Header: Codable {
        var track: LiveTrack
        var startTime: TimeInterval
        var isDiscontinuity: Bool
        /// Missing in a header from before backfill: live audio.
        var isBackfill: Bool?
        var sampleCount: Int
    }

    private static let lengthPrefixSize = MemoryLayout<UInt64>.size
    private static let bytesPerSample = MemoryLayout<UInt32>.size

    public func encodedForXPC() -> Data {
        let header = Header(track: track, startTime: startTime, isDiscontinuity: isDiscontinuity, isBackfill: isBackfill, sampleCount: samples.count)
        // Fails only for a non-finite start time, which the pump never produces;
        // the empty header then makes the receiver reject the chunk.
        let headerData = (try? JSONEncoder().encode(header)) ?? Data()

        var data = Data(capacity: Self.lengthPrefixSize + headerData.count + samples.count * Self.bytesPerSample)
        withUnsafeBytes(of: UInt64(headerData.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(headerData)
        samples.map(\.bitPattern.littleEndian).withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    public init(xpcData data: Data) throws(LiveAudioChunkCodingError) {
        // `withUnsafeBytes` rethrows untyped errors, so the typed error travels in a Result.
        let decoded = data.withUnsafeBytes { bytes in
            Result { () throws(LiveAudioChunkCodingError) in try Self.decode(bytes) }
        }
        let (header, samples) = try decoded.get()
        self.init(
            track: header.track,
            startTime: header.startTime,
            samples: samples,
            isDiscontinuity: header.isDiscontinuity,
            isBackfill: header.isBackfill ?? false
        )
    }

    private static func decode(_ bytes: UnsafeRawBufferPointer) throws(LiveAudioChunkCodingError) -> (Header, [Float]) {
        guard bytes.count >= lengthPrefixSize else { throw .truncatedHeader }
        let headerLength = UInt64(littleEndian: bytes.loadUnaligned(as: UInt64.self))
        guard headerLength <= UInt64(bytes.count - lengthPrefixSize) else { throw .truncatedHeader }

        let headerEnd = lengthPrefixSize + Int(headerLength)
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: Data(bytes[lengthPrefixSize ..< headerEnd]))
        } catch {
            throw .malformedHeader
        }

        let payloadSamples = (bytes.count - headerEnd) / bytesPerSample
        guard header.sampleCount >= 0, (bytes.count - headerEnd) % bytesPerSample == 0, payloadSamples == header.sampleCount else {
            throw .sampleCountMismatch(expected: header.sampleCount, actual: payloadSamples)
        }

        let samples = (0 ..< payloadSamples).map { index in
            let bits = bytes.loadUnaligned(fromByteOffset: headerEnd + index * bytesPerSample, as: UInt32.self)
            return Float(bitPattern: UInt32(littleEndian: bits))
        }
        return (header, samples)
    }
}
