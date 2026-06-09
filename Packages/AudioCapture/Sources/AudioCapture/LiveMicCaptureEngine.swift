import AudioToolbox
@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os
import Synchronization

private let logger = Logger(subsystem: "net.scosman.biscotti.audiocapture", category: "LiveMicCapture")

/// Live microphone capture via **VoiceProcessingIO** (`AVAudioEngine`
/// with `inputNode.setVoiceProcessingEnabled(true)`).
///
/// VPIO is the only route to the loud, normalised, noise-suppressed
/// processed mono (the plain input tap records the raw beamformer array,
/// near-silent during meetings). See `experiments/AudioLab/NOTES.md`.
///
/// This is a thin hardware adapter -- all orchestration lives in
/// `AudioRecorder`. Tested only by the Manual Test App.
final class LiveMicCaptureEngine: CaptureEngine, @unchecked Sendable {
    private let encoder: EncoderSettings
    private let processingFormat: AVAudioFormat

    /// Atomic file ref (bit-pattern of the opaque pointer, 0 = nil).
    /// Lock-free so the real-time tap can read without blocking.
    private let atomicFileRef = Atomic<UInt>(0)

    /// Atomic capturing flag -- safe from async contexts.
    private let capturingFlag = Atomic<Bool>(false)

    private let engineQueue = DispatchQueue(label: "net.scosman.biscotti.mic.engine")
    private var isTearingDown = false
    private var engine: AVAudioEngine?
    private var silenceNode: AVAudioSourceNode?
    private var configObserver: NSObjectProtocol?
    private var outputRateOverride: (deviceID: AudioObjectID, originalRate: Double)?
    private var cachedConverter: AVAudioConverter?
    private var cachedConverterSourceHash: Int = 0

    var onUnrecoverableError: (@Sendable (Error) -> Void)?

    init(encoder: EncoderSettings = .voice) {
        self.encoder = encoder
        processingFormat = encoder.processingFormat
    }

    // MARK: - CaptureEngine conformance

    func start(writingTo url: URL) async throws {
        guard !capturingFlag.load(ordering: .acquiring) else { return }

        engineQueue.sync { isTearingDown = false }

        let file = try VPIOFileHelper.createExtAudioFile(
            url: url, encoder: encoder, processingFormat: processingFormat
        )
        setExtFile(file)
        installConfigChangeObserver()
        capturingFlag.store(true, ordering: .releasing)

        engineQueue.async { [weak self] in
            self?.buildAndStartEngine(context: "initial start")
        }
    }

    func stop() async {
        guard capturingFlag.exchange(false, ordering: .acquiringAndReleasing) else {
            return
        }

        removeConfigChangeObserver()
        engineQueue.sync { [self] in
            isTearingDown = true
            teardownEngine()
            restoreOutputRate()
            closeExtFile()
        }
    }

    func reconnect() async throws {
        guard capturingFlag.load(ordering: .acquiring) else { return }
        engineQueue.sync { [self] in
            guard !isTearingDown else { return }
            teardownEngine()
            buildAndStartEngine(context: "reconnect")
        }
    }

    deinit {
        removeConfigChangeObserver()
        teardownEngine()
        restoreOutputRate()
        let bits = atomicFileRef.load(ordering: .acquiring)
        if bits != 0, let ptr = OpaquePointer(bitPattern: bits) {
            ExtAudioFileDispose(ptr)
        }
    }

    // MARK: - Engine lifecycle (engineQueue)

    private func buildAndStartEngine(context: String) {
        guard capturingFlag.load(ordering: .acquiring) else { return }
        do {
            ensureOutputRateMatchesInput()

            let newEngine = AVAudioEngine()
            // Store before the fallible setup so the catch path's
            // teardownEngine() can stop it / remove the tap / detach
            // the silence node.
            engine = newEngine
            let input = newEngine.inputNode

            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: false, duckingLevel: .min
            )

            let tapFormat = input.outputFormat(forBus: 0)
            attachSilentOutput(to: newEngine, inputRate: tapFormat.sampleRate)

            input.installTap(
                onBus: 0, bufferSize: 1024, format: tapFormat
            ) { [weak self] buffer, _ in
                self?.handleTap(buffer: buffer)
            }

            newEngine.prepare()
            try newEngine.start()
        } catch {
            logger.error("VPIO engine setup failed (\(context)): \(error.localizedDescription)")
            teardownEngine()
            restoreOutputRate()
            closeExtFile()
            capturingFlag.store(false, ordering: .releasing)
            // Dispatch off engineQueue to avoid deadlock if the handler
            // calls stop() (which does engineQueue.sync).
            let handler = onUnrecoverableError
            DispatchQueue.global().async { handler?(error) }
        }
    }

    private func ensureOutputRateMatchesInput() {
        guard let inID = CoreAudioHelpers.defaultInputDeviceID(),
              let inRate = CoreAudioHelpers.nominalSampleRate(for: inID),
              let outID = CoreAudioHelpers.defaultOutputDeviceID(),
              let outRate = CoreAudioHelpers.nominalSampleRate(for: outID)
        else { return }
        guard abs(inRate - outRate) > 1 else { return }
        if outputRateOverride == nil {
            outputRateOverride = (outID, outRate)
        }
        CoreAudioHelpers.setNominalSampleRate(inRate, for: outID)
        for _ in 0 ..< 40 {
            if let now = CoreAudioHelpers.nominalSampleRate(for: outID),
               abs(now - inRate) < 1
            { return }
            usleep(25000)
        }
    }

    private func restoreOutputRate() {
        guard let override = outputRateOverride else { return }
        CoreAudioHelpers.setNominalSampleRate(override.originalRate, for: override.deviceID)
        outputRateOverride = nil
    }

    /// Connects a silent source node straight to `outputNode` (not through
    /// `mainMixerNode`) with sample rate forced to the VPIO input rate.
    private func attachSilentOutput(to engine: AVAudioEngine, inputRate: Double) {
        let output = engine.outputNode
        let hwChannels = max(1, output.outputFormat(forBus: 0).channelCount)
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: inputRate, channels: hwChannels
        ) else { return }

        let node = AVAudioSourceNode(format: format) { isSilence, _, _, bufList in
            isSilence.pointee = ObjCBool(true)
            let abl = UnsafeMutableAudioBufferListPointer(bufList)
            for buf in abl {
                if let data = buf.mData { memset(data, 0, Int(buf.mDataByteSize)) }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: output, format: format)
        silenceNode = node
    }

    private func teardownEngine() {
        if let eng = engine {
            if eng.isRunning { eng.stop() }
            eng.inputNode.removeTap(onBus: 0)
            if let node = silenceNode { eng.detach(node) }
        }
        silenceNode = nil
        engine = nil
        cachedConverter = nil
        cachedConverterSourceHash = 0
    }

    // MARK: - Config-change observer

    private func installConfigChangeObserver() {
        // object: nil is intentional. buildAndStartEngine creates a fresh
        // AVAudioEngine on every rebuild, so scoping to a specific instance
        // would go stale after the first route-change rebuild. This is safe:
        // LiveMicCaptureEngine is the only AVAudioEngine in the package (the
        // system engine uses Core Audio taps, not AVAudioEngine).
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] _ in self?.handleConfigurationChange() }
    }

    private func removeConfigChangeObserver() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
    }

    private func handleConfigurationChange() {
        engineQueue.async { [weak self] in
            guard let self, !isTearingDown else { return }
            teardownEngine()
            buildAndStartEngine(context: "route change")
        }
    }

    // MARK: - Tap (real-time audio thread)

    private func handleTap(buffer: AVAudioPCMBuffer) {
        guard let file = currentExtFile() else { return }
        guard let mono = VPIOBufferHelper.extractChannel0(buffer) else { return }

        let targetFormat = processingFormat
        let bufferToWrite: AVAudioPCMBuffer
        if mono.format.sampleRate == targetFormat.sampleRate {
            bufferToWrite = mono
        } else {
            guard let converter = converterForSource(mono.format),
                  let converted = VPIOBufferHelper.convert(
                      mono, to: targetFormat, using: converter
                  )
            else { return }
            bufferToWrite = converted
        }
        VPIOBufferHelper.writeBuffer(bufferToWrite, to: file)
    }

    private func converterForSource(_ sourceFormat: AVAudioFormat) -> AVAudioConverter? {
        let sourceHash = sourceFormat.hash
        if sourceHash == cachedConverterSourceHash, let converter = cachedConverter {
            return converter
        }
        guard let converter = AVAudioConverter(
            from: sourceFormat, to: processingFormat
        ) else {
            logger.error("Failed to build AVAudioConverter for mic resampling")
            return nil
        }
        cachedConverter = converter
        cachedConverterSourceHash = sourceHash
        return converter
    }

    // MARK: - File handle (lock-free, safe for real-time thread)

    private func setExtFile(_ file: ExtAudioFileRef?) {
        let bits = file.map { UInt(bitPattern: $0) } ?? 0
        atomicFileRef.store(bits, ordering: .releasing)
    }

    private func closeExtFile() {
        let bits = atomicFileRef.exchange(0, ordering: .acquiringAndReleasing)
        if bits != 0, let ptr = OpaquePointer(bitPattern: bits) {
            ExtAudioFileDispose(ptr)
        }
    }

    private func currentExtFile() -> ExtAudioFileRef? {
        let bits = atomicFileRef.load(ordering: .acquiring)
        guard bits != 0 else { return nil }
        return OpaquePointer(bitPattern: bits)
    }
}

// MARK: - Buffer helpers (pure, testable)

/// Pure audio-buffer operations used by the VPIO mic tap. Extracted from the
/// engine class so they can be unit-tested without hardware.
enum VPIOBufferHelper {
    /// Extracts channel 0 of a multichannel non-interleaved float PCM buffer
    /// into a mono buffer at the same sample rate. With VPIO, channel 0 is
    /// the processed/beamformed mono; the rest are raw-array reference feeds.
    static func extractChannel0(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(source.frameLength)
        guard frames > 0, let srcData = source.floatChannelData else { return nil }
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: source.format.sampleRate,
            channels: 1,
            interleaved: false
        ), let mono = AVAudioPCMBuffer(
            pcmFormat: monoFormat,
            frameCapacity: AVAudioFrameCount(frames)
        ) else { return nil }
        mono.frameLength = AVAudioFrameCount(frames)
        guard let dst = mono.floatChannelData?[0] else { return nil }
        dst.update(from: srcData[0], count: frames)
        return mono
    }

    /// Resamples a PCM buffer to `targetFormat` via the supplied converter.
    static func convert(
        _ source: AVAudioPCMBuffer,
        to targetFormat: AVAudioFormat,
        using converter: AVAudioConverter
    ) -> AVAudioPCMBuffer? {
        let frameCapacity = AVAudioFrameCount(
            Double(source.frameLength) * targetFormat.sampleRate / source.format.sampleRate
        )
        guard frameCapacity > 0,
              let output = AVAudioPCMBuffer(
                  pcmFormat: targetFormat, frameCapacity: frameCapacity
              )
        else { return nil }

        var error: NSError?
        nonisolated(unsafe) var hasProvidedData = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if hasProvidedData { outStatus.pointee = .noDataNow; return nil }
            hasProvidedData = true
            outStatus.pointee = .haveData
            return source
        }
        converter.convert(to: output, error: &error, withInputFrom: inputBlock)
        if let error {
            logger.error("AVAudioConverter error: \(error.localizedDescription)")
            return nil
        }
        guard output.frameLength > 0 else { return nil }
        return output
    }

    @discardableResult
    static func writeBuffer(
        _ buffer: AVAudioPCMBuffer, to file: ExtAudioFileRef
    ) -> OSStatus {
        let status = ExtAudioFileWrite(
            file, buffer.frameLength, buffer.mutableAudioBufferList
        )
        if status != noErr {
            logger.error("ExtAudioFileWrite error: \(status)")
        }
        return status
    }
}

// MARK: - File creation helper

/// Encapsulates `ExtAudioFile` creation for the VPIO mic engine.
private enum VPIOFileHelper {
    static func createExtAudioFile(
        url: URL,
        encoder: EncoderSettings,
        processingFormat: AVAudioFormat
    ) throws -> ExtAudioFileRef {
        var outputASBD = encoder.outputASBD()
        var fileRef: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(
            url as CFURL, encoder.fileType, &outputASBD, nil,
            AudioFileFlags.eraseFile.rawValue, &fileRef
        )
        guard createStatus == noErr, let file = fileRef else {
            throw CaptureError.micEngineFailed(
                "Failed to create ADTS AAC file (OSStatus \(createStatus))"
            )
        }
        var clientASBD = processingFormat.streamDescription.pointee
        let clientStatus = ExtAudioFileSetProperty(
            file, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientASBD
        )
        guard clientStatus == noErr else {
            ExtAudioFileDispose(file)
            throw CaptureError.micEngineFailed(
                "Failed to set client format (OSStatus \(clientStatus))"
            )
        }
        let brStatus = EncoderSettings.applyBitRate(
            to: file, bitRate: encoder.bitRate
        )
        if brStatus != noErr {
            logger.warning(
                "applyBitRate returned \(brStatus) — using encoder default"
            )
        }
        return file
    }
}
