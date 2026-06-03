import AVFoundation
import XCTest

@testable import AudioLab

final class EncoderSettingsTests: XCTestCase {
    func testOutputSettingsHaveCorrectFormat() {
        let settings = EncoderSettings.outputSettings
        let formatID = settings[AVFormatIDKey] as? Int
        XCTAssertEqual(formatID, Int(kAudioFormatMPEG4AAC))
    }

    func testOutputSettingsHaveCorrectSampleRate() {
        let settings = EncoderSettings.outputSettings
        let sampleRate = settings[AVSampleRateKey] as? Double
        XCTAssertEqual(sampleRate, 48_000.0)
    }

    func testOutputSettingsAreMono() {
        let settings = EncoderSettings.outputSettings
        let channels = settings[AVNumberOfChannelsKey] as? Int
        XCTAssertEqual(channels, 1)
    }

    func testOutputSettingsHaveCorrectBitRate() {
        let settings = EncoderSettings.outputSettings
        let bitRate = settings[AVEncoderBitRateKey] as? Int
        XCTAssertEqual(bitRate, 64_000)
    }

    func testOutputSettingsHaveHighQuality() {
        let settings = EncoderSettings.outputSettings
        let quality = settings[AVEncoderAudioQualityKey] as? Int
        XCTAssertEqual(quality, AVAudioQuality.high.rawValue)
    }

    func testProcessingFormatMatchesSettings() {
        let format = EncoderSettings.processingFormat
        XCTAssertEqual(format.sampleRate, 48_000.0)
        XCTAssertEqual(format.channelCount, 1)
    }
}
