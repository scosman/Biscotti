import AVFoundation

/// Handles the CAF-to-M4A encode step that runs after capture stops.
///
/// During capture, audio is written as PCM into a CAF file (crash-safe:
/// AAC needs a `pakt` chunk only written on close, so CAF+AAC would lose
/// data on crash). On stop, this manager encodes the CAF to an AAC `.m4a`
/// for long-term storage.
///
/// On encode failure the CAF is **retained** (it is playable everywhere)
/// and a `CaptureError.conversionFailed` is thrown so audio is never lost.
public enum RecordingFileManager {
    /// Encodes a PCM CAF file to an AAC M4A file using the given settings.
    ///
    /// - Parameters:
    ///   - source: URL of the source CAF file (PCM).
    ///   - destination: URL for the output M4A file.
    ///   - settings: Encoder settings (default: `.voiceM4A`).
    /// - Throws: `CaptureError.conversionFailed` if encoding fails.
    ///   The source CAF is always retained on failure.
    public static func encodeToM4A(
        source: URL,
        destination: URL,
        settings: EncoderSettings = .voiceM4A
    ) throws {
        let sourceFile: AVAudioFile
        do {
            sourceFile = try AVAudioFile(forReading: source)
        } catch {
            throw CaptureError.conversionFailed(
                "Failed to open source CAF: \(error.localizedDescription)"
            )
        }

        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(
                forWriting: destination,
                settings: settings.avSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw CaptureError.conversionFailed(
                "Failed to create output M4A: \(error.localizedDescription)"
            )
        }

        let bufferCapacity: AVAudioFrameCount = 8192
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: sourceFile.processingFormat,
            frameCapacity: bufferCapacity
        ) else {
            throw CaptureError.conversionFailed("Failed to allocate read buffer")
        }

        do {
            while sourceFile.framePosition < sourceFile.length {
                try sourceFile.read(into: buffer)
                try outputFile.write(from: buffer)
            }
        } catch {
            // Clean up the partial output but never remove the source CAF.
            try? FileManager.default.removeItem(at: destination)
            throw CaptureError.conversionFailed(
                "Encode loop failed: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Utilities

    /// Returns the size in bytes of the file at the given URL, or 0 if unreadable.
    public static func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    /// Human-readable string for a byte count (e.g. "1.2 MB").
    public static func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
