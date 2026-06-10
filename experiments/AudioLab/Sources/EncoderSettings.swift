import AudioToolbox
import AVFoundation
import Foundation

enum EncoderSettings {
    // 24 kHz: our STT (transcription) models run at 16 kHz internally, so 24 kHz
    // already covers them with headroom for future models that may want higher-rate
    // audio — a small size cost for that margin. 64 kbps mono AAC-LC sits firmly
    // within the codec's comfortable voice range.
    static let sampleRate: Double = 24_000.0
    static let channels: AVAudioChannelCount = 1
    static let bitRate: UInt32 = 64_000
    static let formatID: AudioFormatID = kAudioFormatMPEG4AAC
    static let fileType: AudioFileTypeID = kAudioFileAAC_ADTSType

    /// ASBD for the on-disk AAC output (used by ExtAudioFile).
    static func outputASBD() -> AudioStreamBasicDescription {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = sampleRate
        asbd.mFormatID = formatID
        asbd.mChannelsPerFrame = UInt32(channels)
        return asbd
    }

    /// After setting the client format on an ExtAudioFile, call this to
    /// configure the AAC encoder's bitrate via its underlying AudioConverter.
    /// Returns noErr on success; callers should handle failures.
    @discardableResult
    static func applyBitRate(to extFile: ExtAudioFileRef) -> OSStatus {
        var converterRef: AudioConverterRef?
        var size = UInt32(MemoryLayout<AudioConverterRef>.size)
        var status = ExtAudioFileGetProperty(
            extFile,
            kExtAudioFileProperty_AudioConverter,
            &size,
            &converterRef
        )
        guard status == noErr, let converter = converterRef else { return status }

        var rate = bitRate
        status = AudioConverterSetProperty(
            converter,
            kAudioConverterEncodeBitRate,
            UInt32(MemoryLayout<UInt32>.size),
            &rate
        )
        if status != noErr { return status }

        // Commit the bitrate change. ExtAudioFile caches its converter's state, so
        // after modifying the converter directly we must hand it a NULL converter
        // config to make it re-read the converter. The data MUST be a (NULL)
        // CFArrayRef at pointer size — passing a UInt32 (wrong type/size) makes
        // ExtAudioFile deref garbage as a CFArray and crash (EXC_BAD_ACCESS in
        // CFArrayGetCount).
        var config: UnsafeRawPointer?
        let cfgStatus = ExtAudioFileSetProperty(
            extFile,
            kExtAudioFileProperty_ConverterConfig,
            UInt32(MemoryLayout<UnsafeRawPointer?>.size),
            &config
        )
        return cfgStatus
    }

    /// PCM format the mic tap pre-converts to before encoding (and the
    /// ExtAudioFile client format). Computed once; the force-unwrap is safe for
    /// a valid mono rate.
    static let processingFormat: AVAudioFormat = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate,
        channels: channels
    )!

    /// Compact, log-friendly description of an `AVAudioFormat` (rate, channels,
    /// interleaving, sample-format flags) for diagnostics.
    static func describe(_ format: AVAudioFormat) -> String {
        let asbd = format.streamDescription.pointee
        let layout = format.isInterleaved ? "interleaved" : "deinterleaved"
        let flags = String(asbd.mFormatFlags, radix: 16)
        return "\(Int(format.sampleRate))Hz \(format.channelCount)ch \(layout) " +
            "flags=0x\(flags) bytesPerFrame=\(asbd.mBytesPerFrame)"
    }
}
