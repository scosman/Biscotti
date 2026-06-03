import AVFoundation
import Foundation

enum EncoderSettings {
    static let sampleRate: Double = 48_000.0
    static let channels: AVAudioChannelCount = 1
    static let bitRate: Int = 64_000
    static let formatID: AudioFormatID = kAudioFormatMPEG4AAC

    static var outputSettings: [String: Any] {
        [
            AVFormatIDKey: Int(formatID),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVEncoderBitRateKey: bitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
    }

    static var processingFormat: AVAudioFormat {
        AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: channels
        )!
    }
}
