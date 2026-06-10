import Foundation

/// Caller-provided file URLs for a two-stream capture session.
///
/// Each stream writes ADTS AAC directly during capture via
/// `ExtAudioFile` — no post-recording encode step.
public struct CapturePaths: Sendable {
    /// ADTS AAC file written during mic capture.
    public let micAAC: URL
    /// ADTS AAC file written during system audio capture.
    public let systemAAC: URL

    public init(micAAC: URL, systemAAC: URL) {
        self.micAAC = micAAC
        self.systemAAC = systemAAC
    }
}
