import AudioToolbox
import AVFoundation
import Testing
@testable import AudioCapture

@Suite("EncoderSettings")
struct EncoderSettingsTests {
    @Test("voice has correct sample rate")
    func voiceSampleRate() {
        #expect(EncoderSettings.voice.sampleRate == 24000)
    }

    @Test("voice is mono")
    func voiceChannels() {
        #expect(EncoderSettings.voice.channels == 1)
    }

    @Test("voice has correct bit rate")
    func voiceBitRate() {
        #expect(EncoderSettings.voice.bitRate == 64000)
    }

    @Test("voice formatID is AAC")
    func voiceFormatID() {
        #expect(EncoderSettings.voice.formatID == kAudioFormatMPEG4AAC)
    }

    @Test("voice fileType is ADTS")
    func voiceFileType() {
        #expect(EncoderSettings.voice.fileType == kAudioFileAAC_ADTSType)
    }

    @Test("outputASBD has correct fields")
    func outputASBD() {
        let asbd = EncoderSettings.voice.outputASBD()
        #expect(asbd.mSampleRate == 24000)
        #expect(asbd.mFormatID == kAudioFormatMPEG4AAC)
        #expect(asbd.mChannelsPerFrame == 1)
    }

    @Test("processingFormat matches stored settings")
    func processingFormatMatchesSettings() {
        let format = EncoderSettings.voice.processingFormat
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
        let baseline = EncoderSettings(sampleRate: 24000, channels: 1, bitRate: 64000)
        let preset = EncoderSettings.voice
        #expect(baseline == preset)

        // Differ on sampleRate only.
        let diffRate = EncoderSettings(sampleRate: 48000, channels: 1, bitRate: 64000)
        #expect(baseline != diffRate)

        // Differ on channels only.
        let diffChannels = EncoderSettings(sampleRate: 24000, channels: 2, bitRate: 64000)
        #expect(baseline != diffChannels)

        // Differ on bitRate only.
        let diffBitRate = EncoderSettings(sampleRate: 24000, channels: 1, bitRate: 128_000)
        #expect(baseline != diffBitRate)

        // Differ on formatID only.
        let diffFormatID = EncoderSettings(
            sampleRate: 24000, channels: 1, bitRate: 64000,
            formatID: kAudioFormatAppleLossless
        )
        #expect(baseline != diffFormatID)

        // Differ on fileType only.
        let diffFileType = EncoderSettings(
            sampleRate: 24000, channels: 1, bitRate: 64000,
            fileType: kAudioFileM4AType
        )
        #expect(baseline != diffFileType)
    }
}
