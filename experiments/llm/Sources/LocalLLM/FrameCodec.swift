import Foundation

/// Errors from the frame codec layer.
public enum FrameCodecError: Error, LocalizedError, Sendable, Equatable {
    /// The length prefix exceeds the maximum allowed frame size.
    case oversizeFrame(UInt32)

    /// The stream ended before the full frame could be read (EOF mid-frame).
    case truncatedFrame

    /// JSON encoding or decoding failed.
    case codecError(String)

    public var errorDescription: String? {
        switch self {
        case let .oversizeFrame(size):
            return "Frame size \(size) bytes exceeds the 64 MB limit"
        case .truncatedFrame:
            return "Stream ended before the full frame could be read"
        case let .codecError(detail):
            return "Frame codec error: \(detail)"
        }
    }
}

/// Length-prefixed JSON frame codec for the service wire protocol.
///
/// Each frame is: **4-byte big-endian UInt32 length** + that many bytes of JSON.
/// The codec handles partial reads (reassembly) and validates frame size against
/// a 64 MB sanity cap.
public enum FrameCodec {
    /// Maximum allowed frame payload size: 64 MB.
    public static let maxFrameSize: UInt32 = 64 * 1024 * 1024

    // MARK: - Encode

    /// Encode a value as a length-prefixed JSON frame.
    ///
    /// - Throws: `FrameCodecError.oversizeFrame` if the JSON payload exceeds the
    ///   64 MB cap, `.codecError` if JSON encoding fails.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let json: Data
        do {
            json = try JSONEncoder().encode(value)
        } catch {
            throw FrameCodecError.codecError("JSON encode failed: \(error.localizedDescription)")
        }

        guard json.count <= maxFrameSize else {
            throw FrameCodecError.oversizeFrame(UInt32(min(json.count, Int(UInt32.max))))
        }

        let length = UInt32(json.count)
        var header = length.bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(json)
        return frame
    }

    // MARK: - Decode from FileHandle

    /// Decode a single length-prefixed JSON frame from a `FileHandle`.
    ///
    /// Blocks until the full frame is available. Handles partial reads via a
    /// read-exactly-N reassembly loop.
    ///
    /// - Throws: `FrameCodecError.truncatedFrame` on EOF mid-frame,
    ///   `.oversizeFrame` if the length header exceeds the 64 MB cap,
    ///   `.codecError` if JSON decoding fails.
    public static func decode<T: Decodable>(_ type: T.Type, from handle: FileHandle) throws -> T {
        // Read the 4-byte length header.
        let headerData = try readExactly(count: 4, from: handle)
        let length = headerData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

        guard length <= maxFrameSize else {
            throw FrameCodecError.oversizeFrame(length)
        }

        // A zero-length frame is valid JSON-wise only for specific types;
        // let the decoder decide.
        guard length > 0 else {
            do {
                return try JSONDecoder().decode(type, from: Data())
            } catch {
                throw FrameCodecError.codecError("JSON decode failed: \(error.localizedDescription)")
            }
        }

        let payload = try readExactly(count: Int(length), from: handle)

        do {
            return try JSONDecoder().decode(type, from: payload)
        } catch {
            throw FrameCodecError.codecError("JSON decode failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Decode from Data buffer

    /// Decode a single length-prefixed JSON frame from a `Data` buffer.
    ///
    /// On success, returns the decoded value and the number of bytes consumed
    /// (header + payload). Returns `nil` if the buffer doesn't contain a
    /// complete frame yet (useful for incremental buffering).
    ///
    /// - Throws: `.oversizeFrame` if the length exceeds the cap,
    ///   `.codecError` if JSON decoding fails on a complete frame.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> (value: T, consumed: Int)? {
        guard data.count >= 4 else { return nil }

        let length = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

        guard length <= maxFrameSize else {
            throw FrameCodecError.oversizeFrame(length)
        }

        let totalNeeded = 4 + Int(length)
        guard data.count >= totalNeeded else { return nil }

        let payload = data[data.startIndex + 4 ..< data.startIndex + totalNeeded]

        do {
            let value = try JSONDecoder().decode(type, from: payload)
            return (value, totalNeeded)
        } catch {
            throw FrameCodecError.codecError("JSON decode failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Internal

    /// Read exactly `count` bytes from a FileHandle, reassembling partial reads.
    private static func readExactly(count: Int, from handle: FileHandle) throws -> Data {
        var remaining = count
        var buffer = Data(capacity: count)

        while remaining > 0 {
            let chunk = handle.readData(ofLength: remaining)
            if chunk.isEmpty {
                throw FrameCodecError.truncatedFrame
            }
            buffer.append(chunk)
            remaining -= chunk.count
        }

        return buffer
    }
}
