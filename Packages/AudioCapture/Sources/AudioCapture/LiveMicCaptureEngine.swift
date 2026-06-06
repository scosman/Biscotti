import AudioToolbox
@preconcurrency import AVFoundation
import Foundation
import os
import Synchronization

private let logger = Logger(subsystem: "net.scosman.biscotti.audiocapture", category: "LiveMicCapture")

/// Live microphone capture via AVAudioEngine input-node tap.
///
/// Writes PCM to a CAF file. Handles route-change survival internally:
/// on `AVAudioEngineConfigurationChange`, re-queries the input format,
/// reinstalls the tap with a fresh converter, and restarts the engine.
///
/// This is a thin hardware adapter -- all orchestration lives in
/// `AudioRecorder`. Tested only by the Manual Test App.
final class LiveMicCaptureEngine: CaptureEngine, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let processingFormat: AVAudioFormat

    /// Stores the `ExtAudioFileRef` (an opaque pointer) as an atomic integer
    /// so the real-time tap callback can read it without taking a lock.
    /// The value is the bit-pattern of the pointer, or 0 when nil.
    ///
    /// Safety: the pointer is only invalidated (via `ExtAudioFileDispose`)
    /// after the tap has been removed and the engine stopped, so no reader
    /// can observe a dangling pointer.
    private let atomicFileRef = Atomic<UInt>(0)

    /// Atomic state flag -- avoids locking in async contexts.
    private let capturingFlag = Atomic<Bool>(false)

    private let configQueue = DispatchQueue(label: "net.scosman.biscotti.mic.config")
    private var configObserver: NSObjectProtocol?
    private var reconfigureGeneration = 0
    private var isTearingDown = false

    var onUnrecoverableError: (@Sendable (Error) -> Void)?

    init(encoder: EncoderSettings = .voiceM4A) {
        processingFormat = encoder.processingFormat
    }

    func start(writingTo url: URL) async throws {
        guard !capturingFlag.load(ordering: .acquiring) else { return }

        configQueue.sync {
            isTearingDown = false
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        let file = try Self.createExtAudioFile(
            url: url,
            clientFormat: processingFormat
        )
        setExtFile(file)

        do {
            try installTap(inputFormat: inputFormat)
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            closeExtFile()
            throw CaptureError.micEngineFailed(error.localizedDescription)
        }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }

        capturingFlag.store(true, ordering: .releasing)
    }

    /// Reconnects the mic engine hardware without reopening the audio file.
    ///
    /// For the mic engine, this triggers the same file-preserving reconfigure
    /// path that `AVAudioEngineConfigurationChange` uses internally: the tap
    /// and engine are rebuilt but the ExtAudioFile stays open and continues
    /// receiving writes.
    func reconnect() async throws {
        guard capturingFlag.load(ordering: .acquiring) else { return }
        configQueue.sync {
            guard !isTearingDown else { return }
            reconfigure()
        }
    }

    func stop() async {
        guard capturingFlag.exchange(false, ordering: .acquiringAndReleasing) else { return }

        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }

        configQueue.sync {
            isTearingDown = true
            reconfigureGeneration += 1
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        closeExtFile()
    }

    // MARK: - ExtAudioFile creation

    private static func createExtAudioFile(
        url: URL,
        clientFormat: AVAudioFormat
    ) throws -> ExtAudioFileRef {
        // Write PCM to CAF (crash-safe: no pakt chunk needed for uncompressed).
        var cafASBD = clientFormat.streamDescription.pointee
        var fileRef: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(
            url as CFURL,
            kAudioFileCAFType,
            &cafASBD,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &fileRef
        )
        guard createStatus == noErr, let file = fileRef else {
            throw CaptureError.micEngineFailed(
                "Failed to create CAF file (OSStatus \(createStatus))"
            )
        }

        // Client format matches the file format (PCM), so no converter needed.
        var clientASBD = clientFormat.streamDescription.pointee
        let clientStatus = ExtAudioFileSetProperty(
            file,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientASBD
        )
        guard clientStatus == noErr else {
            ExtAudioFileDispose(file)
            throw CaptureError.micEngineFailed(
                "Failed to set client format (OSStatus \(clientStatus))"
            )
        }

        return file
    }

    // MARK: - Tap installation

    private func installTap(inputFormat: AVAudioFormat) throws {
        let targetFormat = processingFormat
        let inputNode = engine.inputNode

        let needsConversion =
            inputFormat.sampleRate != targetFormat.sampleRate
                || inputFormat.channelCount != targetFormat.channelCount

        if needsConversion {
            guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw CaptureError.micEngineFailed(
                    "Cannot create converter for input \(inputFormat)"
                )
            }

            inputNode.installTap(
                onBus: 0, bufferSize: 4096, format: inputFormat
            ) { [weak self] buffer, _ in
                guard let self, let file = currentExtFile() else { return }

                let frameCapacity = AVAudioFrameCount(
                    Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate
                )
                guard let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat, frameCapacity: frameCapacity
                ) else { return }

                var error: NSError?
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
                    Self.writeBuffer(convertedBuffer, to: file)
                }
            }
        } else {
            inputNode.installTap(
                onBus: 0, bufferSize: 4096, format: inputFormat
            ) { [weak self] buffer, _ in
                guard let self, let file = currentExtFile() else { return }
                Self.writeBuffer(buffer, to: file)
            }
        }
    }

    private static func writeBuffer(_ buffer: AVAudioPCMBuffer, to file: ExtAudioFileRef) {
        let bufferList = buffer.mutableAudioBufferList
        let status = ExtAudioFileWrite(file, buffer.frameLength, bufferList)
        if status != noErr {
            logger.error("ExtAudioFileWrite error: \(status)")
        }
    }

    // MARK: - Route-change handling

    private func handleConfigurationChange() {
        configQueue.async { [weak self] in
            guard let self else { return }
            guard !isTearingDown else { return }

            reconfigureGeneration += 1
            let generation = reconfigureGeneration

            configQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                guard !isTearingDown else { return }
                guard generation == reconfigureGeneration else { return }
                reconfigure()
            }
        }
    }

    private func reconfigure() {
        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)
        engine.stop()

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            logger.info("Skipping reconfigure: input format not ready")
            return
        }

        do {
            try installTap(inputFormat: inputFormat)
            engine.prepare()
            try engine.start()
        } catch {
            logger.error("Reconfigure failed: \(error.localizedDescription)")
            onUnrecoverableError?(error)
            capturingFlag.store(false, ordering: .releasing)
        }
    }

    // MARK: - Shared-state accessors (lock-free, safe for real-time thread)

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

    deinit {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if capturingFlag.load(ordering: .acquiring) {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        let bits = atomicFileRef.load(ordering: .acquiring)
        if bits != 0, let ptr = OpaquePointer(bitPattern: bits) {
            ExtAudioFileDispose(ptr)
        }
    }
}
