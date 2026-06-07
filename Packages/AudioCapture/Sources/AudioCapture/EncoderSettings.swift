import AudioToolbox
import AVFoundation

/// Configures the audio encoding format for recorded files.
///
/// The resolved default (`.voice`) is ADTS AAC-LC, mono, 24 kHz, 64 kbps.
/// 24 kHz covers the 16 kHz STT models with headroom for future higher-rate
/// models, at a small size cost. 64 kbps mono AAC-LC sits firmly within the
/// codec's comfortable voice range.
public struct EncoderSettings: Sendable, Equatable {
    public let sampleRate: Double
    public let channels: Int
    public let bitRate: Int
    public let formatID: AudioFormatID
    public let fileType: AudioFileTypeID

    public init(
        sampleRate: Double,
        channels: Int,
        bitRate: Int,
        formatID: AudioFormatID = kAudioFormatMPEG4AAC,
        fileType: AudioFileTypeID = kAudioFileAAC_ADTSType
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitRate = bitRate
        self.formatID = formatID
        self.fileType = fileType
    }

    /// The resolved voice-recording preset: ADTS AAC-LC, mono, 24 kHz, 64 kbps.
    public static let voice = EncoderSettings(
        sampleRate: 24000,
        channels: 1,
        bitRate: 64000,
        formatID: kAudioFormatMPEG4AAC,
        fileType: kAudioFileAAC_ADTSType
    )

    /// Returns an `AudioStreamBasicDescription` for the output file format.
    ///
    /// Only `mFormatID`, `mSampleRate`, and `mChannelsPerFrame` are set;
    /// all other fields are zeroed so the encoder fills them in.
    public func outputASBD() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: formatID,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
    }

    /// Commits the target bit rate on an already-opened `ExtAudioFileRef`.
    ///
    /// Must be called **after** setting `kExtAudioFileProperty_ClientDataFormat`
    /// so the internal AudioConverter exists.
    ///
    /// The commit step uses `kExtAudioFileProperty_ConverterConfig` with a
    /// **NULL `CFArrayRef`** (pointer-sized). Passing a `UInt32` instead causes
    /// `EXC_BAD_ACCESS` inside `CFArrayGetCount`.
    @discardableResult
    public static func applyBitRate(to extFile: ExtAudioFileRef, bitRate: Int = 64000) -> OSStatus {
        // 1. Retrieve the AudioConverter from the ExtAudioFile.
        var converterSize = UInt32(MemoryLayout<AudioConverterRef>.size)
        var converter: AudioConverterRef?
        let getStatus = ExtAudioFileGetProperty(
            extFile,
            kExtAudioFileProperty_AudioConverter,
            &converterSize,
            &converter
        )
        guard getStatus == noErr, let audioConverter = converter else {
            return getStatus
        }

        // 2. Set the encode bit rate on the converter.
        var rate = UInt32(bitRate)
        let setStatus = AudioConverterSetProperty(
            audioConverter,
            kAudioConverterEncodeBitRate,
            UInt32(MemoryLayout<UInt32>.size),
            &rate
        )
        guard setStatus == noErr else {
            return setStatus
        }

        // 3. Commit the converter config change back to ExtAudioFile.
        //    The value is a NULL CFArrayRef (pointer-sized).
        var nullArray: CFArray?
        return ExtAudioFileSetProperty(
            extFile,
            kExtAudioFileProperty_ConverterConfig,
            UInt32(MemoryLayout<CFArray?>.size),
            &nullArray
        )
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
