import Foundation

/// Caller-provided file URLs for a two-stream capture session.
///
/// During capture, PCM audio is written to the CAF files (crash-safe).
/// On stop, each CAF is encoded to AAC `.m4a` at the corresponding
/// output URL.
public struct CapturePaths: Sendable {
    /// PCM CAF written during mic capture.
    public let micCAF: URL
    /// PCM CAF written during system audio capture.
    public let systemCAF: URL
    /// AAC `.m4a` produced from the mic CAF on stop.
    public let micOutput: URL
    /// AAC `.m4a` produced from the system CAF on stop.
    public let systemOutput: URL

    public init(micCAF: URL, systemCAF: URL, micOutput: URL, systemOutput: URL) {
        self.micCAF = micCAF
        self.systemCAF = systemCAF
        self.micOutput = micOutput
        self.systemOutput = systemOutput
    }
}
