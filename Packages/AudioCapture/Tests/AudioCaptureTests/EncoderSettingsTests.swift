import AVFoundation
import Testing
@testable import AudioCapture

@Suite("EncoderSettings")
struct EncoderSettingsTests {
    @Test("voiceM4A has correct sample rate")
    func voiceM4ASampleRate() {
        #expect(EncoderSettings.voiceM4A.sampleRate == 24000)
    }

    @Test("voiceM4A is mono")
    func voiceM4AChannels() {
        #expect(EncoderSettings.voiceM4A.channels == 1)
    }

    @Test("voiceM4A has correct bit rate")
    func voiceM4ABitRate() {
        #expect(EncoderSettings.voiceM4A.bitRate == 64000)
    }

    @Test("avSettings contains AAC format ID")
    func avSettingsFormatID() {
        let settings = EncoderSettings.voiceM4A.avSettings
        let formatID = settings[AVFormatIDKey] as? Int
        #expect(formatID == Int(kAudioFormatMPEG4AAC))
    }

    @Test("avSettings contains correct sample rate")
    func avSettingsSampleRate() {
        let settings = EncoderSettings.voiceM4A.avSettings
        let sampleRate = settings[AVSampleRateKey] as? Double
        #expect(sampleRate == 24000)
    }

    @Test("avSettings is mono")
    func avSettingsChannels() {
        let settings = EncoderSettings.voiceM4A.avSettings
        let channels = settings[AVNumberOfChannelsKey] as? Int
        #expect(channels == 1)
    }

    @Test("avSettings has correct bit rate")
    func avSettingsBitRate() {
        let settings = EncoderSettings.voiceM4A.avSettings
        let bitRate = settings[AVEncoderBitRateKey] as? Int
        #expect(bitRate == 64000)
    }

    @Test("avSettings has high quality")
    func avSettingsQuality() {
        let settings = EncoderSettings.voiceM4A.avSettings
        let quality = settings[AVEncoderAudioQualityKey] as? Int
        #expect(quality == AVAudioQuality.high.rawValue)
    }

    @Test("processingFormat matches stored settings")
    func processingFormatMatchesSettings() {
        let format = EncoderSettings.voiceM4A.processingFormat
        #expect(format.sampleRate == 24000)
        #expect(format.channelCount == 1)
    }

    @Test("custom settings are stored correctly")
    func customSettings() {
        let custom = EncoderSettings(sampleRate: 48000, channels: 2, bitRate: 128_000)
        #expect(custom.sampleRate == 48000)
        #expect(custom.channels == 2)
        #expect(custom.bitRate == 128_000)
    }

    @Test("equatable compares by stored properties")
    func equatable() {
        let manual = EncoderSettings(sampleRate: 24000, channels: 1, bitRate: 64000)
        let preset = EncoderSettings.voiceM4A
        #expect(manual == preset)

        let different = EncoderSettings(sampleRate: 48000, channels: 1, bitRate: 64000)
        #expect(manual != different)
    }
}
