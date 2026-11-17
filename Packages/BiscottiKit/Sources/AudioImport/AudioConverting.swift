import Foundation

/// Seam for audio file conversion. The live implementation decodes the
/// source's first audio track and writes ADTS AAC-LC mono 24 kHz 64 kbps
/// to the destination.
public protocol AudioConverting: Sendable {
    /// Decodes `source`'s first enabled audio track and writes ADTS AAC-LC
    /// mono 24 kHz 64 kbps to `destination` (overwriting). On any failure
    /// the destination is removed before throwing.
    func convert(
        source: URL, destination: URL
    ) async throws -> ConversionResult
}
