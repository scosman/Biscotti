import AVFoundation
import os

private let logger = Logger(
    subsystem: "net.scosman.biscotti.audiocapture",
    category: "ProbeTonePlayer"
)

/// Plays a continuous low-amplitude sine wave to the default system output
/// for the duration of a permission probe.
///
/// The global system tap captures the digital mix with `muteBehavior = .unmuted`,
/// so the amplitude can be tiny (effectively inaudible) yet still register as
/// non-zero regardless of the user's hardware volume or mute state.
///
/// **Tone parameters are HW-tuned.** Detection only needs ANY non-zero
/// sample within the first ~2 s window (`LiveSystemPermissionChecker.ingestSamples`
/// checks `sample != 0.0`, no RMS threshold), and the process tap captures the
/// system mix upstream of the output device's DAC/codec encoding, so amplitude
/// has large margin. We chose a low frequency (~150 Hz) + ultra-low amplitude
/// (~-80 dBFS) for inaudibility per HW validation.
///
/// - Note: TODO — if the low-frequency/ultra-low-amplitude tone proves unreliable
///   on some output paths (e.g. Bluetooth codecs that gate silence), fall back to a
///   high-frequency (~18-19 kHz) tone or a brief slightly louder blip. See
///   specs/architecture.md section 2.4.
final class ProbeTonePlayer: @unchecked Sendable {
    // MARK: - Tunable constants (HW-tuned)

    /// Tone frequency in Hz. ~150 Hz is well below the audible-speech band
    /// and inaudible at the probe amplitude. Low frequencies avoid codec
    /// high-pass filters while remaining well above DC (0 Hz).
    static let toneFrequency: Double = 150.0

    /// Peak amplitude of the sine wave (linear, 0-1 range). 0.0001 is
    /// approximately -80 dBFS -- far below audibility through any speaker
    /// yet well above the digital noise floor (the checker only needs
    /// `!= 0.0`). The process tap captures upstream of the output device,
    /// so the full digital precision is available.
    static let toneAmplitude: Float = 0.0001

    // MARK: - State

    private var engine: AVAudioEngine?
    private var isPlaying = false

    // MARK: - Start / Stop

    /// Begins playing the probe tone to the current default output device.
    ///
    /// Creates a fresh `AVAudioEngine` each time (the engine is short-lived
    /// -- only active for the ~5 s probe window). Throws if the engine
    /// refuses to start (caller treats this as "not observed").
    func start() throws {
        guard !isPlaying else { return }

        let audioEngine = AVAudioEngine()
        let sampleRate = audioEngine.outputNode.outputFormat(
            forBus: 0
        ).sampleRate
        guard sampleRate > 0 else {
            logger.error(
                "ProbeTonePlayer: output node reports 0 sample rate"
            )
            throw CaptureError.probeFailed(
                "Probe tone: output node has 0 sample rate"
            )
        }

        let (sourceNode, format) = try makeSineSourceNode(
            sampleRate: sampleRate
        )

        audioEngine.attach(sourceNode)
        audioEngine.connect(
            sourceNode,
            to: audioEngine.mainMixerNode,
            format: format
        )

        try audioEngine.start()
        engine = audioEngine
        isPlaying = true
        logger.info(
            "Probe tone started (\(Self.toneFrequency, privacy: .public) Hz, amplitude \(Self.toneAmplitude, privacy: .public))"
        )
    }

    /// Creates a source node that renders a sine wave at the configured
    /// frequency and amplitude.
    private func makeSineSourceNode(
        sampleRate: Double
    ) throws -> (AVAudioSourceNode, AVAudioFormat) {
        let amplitude = Self.toneAmplitude
        var phase: Double = 0
        let phaseIncrement = Self.toneFrequency / sampleRate

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) else {
            throw CaptureError.probeFailed(
                "Probe tone: failed to create audio format"
            )
        }

        let node = AVAudioSourceNode { _, _, frameCount, bufferList in
            let ablPointer = UnsafeMutableAudioBufferListPointer(
                bufferList
            )
            for frame in 0 ..< Int(frameCount) {
                let sample = Float(sin(phase * 2.0 * .pi)) * amplitude
                phase += phaseIncrement
                if phase >= 1.0 { phase -= 1.0 }
                for buffer in ablPointer {
                    let buf = UnsafeMutableBufferPointer<Float>(buffer)
                    buf[frame] = sample
                }
            }
            return noErr
        }

        return (node, format)
    }

    /// Stops the probe tone. Idempotent -- safe to call when not playing.
    func stop() {
        guard isPlaying else { return }
        engine?.stop()
        engine = nil
        isPlaying = false
        logger.info("Probe tone stopped")
    }
}
