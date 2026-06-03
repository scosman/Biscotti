@preconcurrency import AVFoundation
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

    func start() throws {
        lock.lock()
        guard !_isCapturing else {
            lock.unlock()
            return
        }
        lock.unlock()

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
