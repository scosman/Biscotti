@preconcurrency import AVFoundation
import CoreAudio
import Foundation

final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private let fileURL: URL

    private let lock = NSLock()
    private var _isCapturing = false

    var isCapturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCapturing
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Pin `AVAudioEngine`'s input node to the given audio device.
    ///
    /// `AVAudioEngine` uses an implicit `kAudioUnitSubType_HALOutput`
    /// AudioUnit under the hood. By default, the HAL I/O unit references
    /// both the system default input and output devices. When an aggregate
    /// device is created for a Core Audio process tap (especially in
    /// per-process mode), macOS may reconfigure the output device's stream
    /// graph, which can disrupt the HAL I/O unit's output side and
    /// silently prevent the input side from delivering buffers.
    ///
    /// Explicitly setting `kAudioOutputUnitProperty_CurrentDevice` on the
    /// underlying AudioUnit pins the engine to a specific device and
    /// isolates it from changes to the system default output device.
    private func pinInputDevice(_ deviceID: AudioObjectID) throws {
        let inputNode = engine.inputNode
        let audioUnit = inputNode.audioUnit!
        var devID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard status == noErr else {
            throw AudioLabError.micEngineStartFailed(
                NSError(
                    domain: "AudioLab", code: Int(status),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Failed to set input device on AVAudioEngine (OSStatus \(status))"
                    ]
                )
            )
        }
    }

    func start() throws {
        lock.lock()
        guard !_isCapturing else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Resolve the default input device and explicitly pin the engine
        // to it so that aggregate-device creation for the system audio tap
        // (especially in per-process mode) does not disrupt the mic stream.
        guard let inputDeviceID = CoreAudioHelpers.defaultInputDeviceID() else {
            throw AudioLabError.micEngineStartFailed(
                NSError(
                    domain: "AudioLab", code: -1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "No default input device available"
                    ]
                )
            )
        }
        try pinInputDevice(inputDeviceID)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        let file = try AVAudioFile(
            forWriting: fileURL,
            settings: EncoderSettings.outputSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        audioFile = file

        let targetFormat = EncoderSettings.processingFormat

        // Install a converter if needed, then a tap
        if inputFormat.sampleRate != targetFormat.sampleRate ||
            inputFormat.channelCount != targetFormat.channelCount
        {
            guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw AudioLabError.micEngineStartFailed(
                    NSError(
                        domain: "AudioLab", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Cannot create audio converter"])
                )
            }

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
                [weak self] buffer, _ in
                guard let self, let file = self.audioFile else { return }

                let frameCapacity = AVAudioFrameCount(
                    Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate
                )
                guard let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat, frameCapacity: frameCapacity
                ) else { return }

                var error: NSError?
                // The inputBlock is called synchronously within convert(), so
                // this flag is safe despite the @Sendable annotation on the block.
                nonisolated(unsafe) var hasProvidedData = false
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                    if hasProvidedData {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    hasProvidedData = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

                if error == nil, convertedBuffer.frameLength > 0 {
                    do {
                        try file.write(from: convertedBuffer)
                    } catch {
                        print("[MicCapture] Write error: \(error)")
                    }
                }
            }
        } else {
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
                [weak self] buffer, _ in
                guard let self, let file = self.audioFile else { return }
                do {
                    try file.write(from: buffer)
                } catch {
                    print("[MicCapture] Write error: \(error)")
                }
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw AudioLabError.micEngineStartFailed(error)
        }

        lock.lock()
        _isCapturing = true
        lock.unlock()
    }

    func stop() {
        lock.lock()
        guard _isCapturing else {
            lock.unlock()
            return
        }
        _isCapturing = false
        lock.unlock()

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil
    }

    deinit {
        if _isCapturing {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }
}
