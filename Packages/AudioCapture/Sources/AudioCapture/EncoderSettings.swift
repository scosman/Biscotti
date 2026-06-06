import AVFoundation

/// Configures the audio encoding format for recorded files.
///
/// The resolved default (`voiceM4A`) is ADTS AAC-LC, mono, 24 kHz, 64 kbps.
/// 24 kHz covers the 16 kHz STT models with headroom for future higher-rate
/// models, at a small size cost. 64 kbps mono AAC-LC sits firmly within the
/// codec's comfortable voice range.
public struct EncoderSettings: Sendable, Equatable {
    public let sampleRate: Double
    public let channels: Int
    public let bitRate: Int

    public init(sampleRate: Double, channels: Int, bitRate: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitRate = bitRate
    }

    /// The resolved voice-recording preset: ADTS AAC-LC, mono, 24 kHz, 64 kbps.
    public static let voiceM4A = EncoderSettings(
        sampleRate: 24000,
        channels: 1,
        bitRate: 64000
    )

    /// Dictionary suitable for `AVAudioFile` output settings or `AVAudioConverter`.
    public var avSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
    }

    /// PCM format for the mic tap pre-conversion (and the ExtAudioFile client
    /// format). Returns a standard float format at the configured sample rate
    /// and channel count.
    public var processingFormat: AVAudioFormat {
        // AVAudioFormat only returns nil for invalid channel layouts;
        // standard mono/stereo rates always succeed.
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channels)
        ) else {
            preconditionFailure("AVAudioFormat refused rate=\(sampleRate) channels=\(channels)")
        }
        return format
    }
}
